// Microsoft Entra ID (Azure AD) credentials and Azure Storage shared key /
// SAS helpers.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../cloud_common.dart';
import 'token_cache.dart';

/// Source of Entra ID access tokens.
abstract class AzureCredential {
  const AzureCredential();

  /// Token for [scope] (e.g. `https://storage.azure.com/.default`).
  Future<AccessToken> getToken(String scope);

  /// Short description for the UI.
  String get description;
}

String _resource(String scope) => scope.endsWith('/.default') ? scope.substring(0, scope.length - 9) : scope;

/// `az account get-access-token` (the user must have run `az login`).
class AzureCliCredential extends AzureCredential {
  const AzureCliCredential({this.tenantId});
  final String? tenantId;

  @override
  String get description => 'Azure CLI';

  @override
  Future<AccessToken> getToken(String scope) => tokenCache.get('az-cli:${tenantId ?? ''}:$scope', () async {
    final args = [
      'account',
      'get-access-token',
      '--resource',
      _resource(scope),
      if (tenantId != null && tenantId!.isNotEmpty) ...['--tenant', tenantId!],
      '-o',
      'json',
    ];
    String out;
    try {
      out = await runCli('az', args);
    } on CloudException catch (e) {
      if (e.message.contains('az login') || e.message.contains('AADSTS')) {
        throw CloudException('Azure CLI non autenticato: esegui "az login" e riprova.\n\n${e.message}');
      }
      rethrow;
    }
    final j = jsonDecode(out) as Map;
    final token = j['accessToken'] as String;
    final epoch = j['expires_on'];
    DateTime exp;
    if (epoch is num) {
      exp = DateTime.fromMillisecondsSinceEpoch(epoch.toInt() * 1000);
    } else {
      exp = DateTime.tryParse('${j['expiresOn']}') ?? DateTime.now().add(const Duration(minutes: 30));
    }
    return AccessToken(token, exp);
  });
}

/// OAuth2 client credentials flow with an app registration secret.
class AzureClientSecretCredential extends AzureCredential {
  const AzureClientSecretCredential({
    required this.tenantId,
    required this.clientId,
    required this.clientSecret,
    this.authority = 'https://login.microsoftonline.com',
  });
  final String tenantId;
  final String clientId;
  final String clientSecret;
  final String authority;

  @override
  String get description => 'Service principal $clientId';

  @override
  Future<AccessToken> getToken(String scope) => tokenCache.get('az-sp:$tenantId:$clientId:$scope', () async {
    if (tenantId.isEmpty || clientId.isEmpty || clientSecret.isEmpty) {
      throw CloudException('Tenant ID, client ID e client secret sono obbligatori.');
    }
    final r = await cloudRequest(
      'POST',
      Uri.parse('$authority/$tenantId/oauth2/v2.0/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: utf8.encode(
        Uri(
          queryParameters: {
            'grant_type': 'client_credentials',
            'client_id': clientId,
            'client_secret': clientSecret,
            'scope': scope,
          },
        ).query,
      ),
      operation: 'Accesso Entra ID',
    );
    final j = jsonDecode(r.text) as Map;
    return AccessToken.expiresIn(j['access_token'] as String, j['expires_in']);
  });
}

/// Managed identity of an Azure VM / App Service / Container App.
class AzureManagedIdentityCredential extends AzureCredential {
  const AzureManagedIdentityCredential({this.clientId});
  final String? clientId;

  @override
  String get description => 'Managed identity';

  @override
  Future<AccessToken> getToken(String scope) => tokenCache.get('az-mi:${clientId ?? ''}:$scope', () async {
    final env = Platform.environment;
    final endpoint = env['IDENTITY_ENDPOINT'];
    final header = env['IDENTITY_HEADER'];
    final cid = clientId == null || clientId!.isEmpty ? null : clientId;
    http.Response r;
    try {
      if (endpoint != null && header != null) {
        // App Service / Functions / Container Apps.
        r = await cloudRequest(
          'GET',
          Uri.parse(endpoint)
              .replace(queryParameters: {'api-version': '2019-08-01', 'resource': _resource(scope), 'client_id': ?cid}),
          headers: {'X-IDENTITY-HEADER': header},
          timeout: const Duration(seconds: 5),
        );
      } else {
        r = await cloudRequest(
          'GET',
          Uri.parse('http://169.254.169.254/metadata/identity/oauth2/token')
              .replace(queryParameters: {'api-version': '2018-02-01', 'resource': _resource(scope), 'client_id': ?cid}),
          headers: {'Metadata': 'true'},
          timeout: const Duration(milliseconds: 1500),
        );
      }
    } on CloudException catch (e) {
      if (e.statusCode == null) {
        throw CloudException(
          'Managed identity non disponibile: DbCraft non è in esecuzione su una risorsa '
          'Azure con identità gestita.',
        );
      }
      rethrow;
    }
    final j = jsonDecode(r.text) as Map;
    final token = j['access_token'] as String;
    final on = int.tryParse('${j['expires_on']}');
    return on != null
        ? AccessToken(token, DateTime.fromMillisecondsSinceEpoch(on * 1000))
        : AccessToken.expiresIn(token, j['expires_in']);
  });
}

/// Fixed token supplied by the user.
class AzureStaticTokenCredential extends AzureCredential {
  const AzureStaticTokenCredential(this.token);
  final String token;

  @override
  String get description => 'Token';

  @override
  Future<AccessToken> getToken(String scope) async =>
      AccessToken(token, DateTime.now().add(const Duration(minutes: 30)));
}

// ---------------------------------------------------------------------------
// Storage account keys, connection strings, SAS
// ---------------------------------------------------------------------------

/// Parsed Azure Storage connection string.
class AzureConnectionString {
  AzureConnectionString(this.values);
  final Map<String, String> values;

  static AzureConnectionString parse(String s) {
    final m = <String, String>{};
    for (final part in s.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      m[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
    }
    if (s.trim() == 'UseDevelopmentStorage=true') {
      m['AccountName'] = 'devstoreaccount1';
      m['AccountKey'] = 'Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==';
      m['BlobEndpoint'] = 'http://127.0.0.1:10000/devstoreaccount1';
    }
    return AzureConnectionString(m);
  }

  String? get accountName => values['AccountName'];
  String? get accountKey => values['AccountKey'];
  String? get sas => values['SharedAccessSignature'];

  /// Blob service endpoint without trailing slash.
  String? get blobEndpoint {
    final e = values['BlobEndpoint'];
    if (e != null && e.isNotEmpty) return e.endsWith('/') ? e.substring(0, e.length - 1) : e;
    final name = accountName;
    if (name == null) return null;
    final proto = values['DefaultEndpointsProtocol'] ?? 'https';
    final suffix = values['EndpointSuffix'] ?? 'core.windows.net';
    return '$proto://$name.blob.$suffix';
  }
}

/// Shared Key authorization for the Blob service.
class AzureSharedKey {
  AzureSharedKey(this.accountName, String accountKey) : _key = base64Decode(accountKey);
  final String accountName;
  final List<int> _key;

  /// String-to-sign of the Blob service (version 2015-02-21 and later).
  String stringToSign(String method, Uri uri, Map<String, String> headers) {
    final h = <String, String>{};
    headers.forEach((k, v) => h[k.toLowerCase()] = v);
    String g(String n) => h[n] ?? '';
    final len = g('content-length');
    final msHeaders = h.keys.where((k) => k.startsWith('x-ms-')).toList()..sort();
    final canonHeaders = msHeaders.map((k) => '$k:${h[k]!.trim().replaceAll(RegExp(r'\s+'), ' ')}\n').join();
    final params = <String, List<String>>{};
    uri.queryParametersAll.forEach((k, v) => params.putIfAbsent(k.toLowerCase(), () => []).addAll(v));
    final pkeys = params.keys.toList()..sort();
    final path = uri.path.isEmpty ? '/' : uri.path;
    final resource = StringBuffer('/$accountName$path');
    for (final k in pkeys) {
      final vs = params[k]!..sort();
      resource.write('\n$k:${vs.join(',')}');
    }
    return [
      method.toUpperCase(),
      g('content-encoding'),
      g('content-language'),
      len == '0' ? '' : len,
      g('content-md5'),
      g('content-type'),
      g('date'),
      g('if-modified-since'),
      g('if-match'),
      g('if-none-match'),
      g('if-unmodified-since'),
      g('range'),
      '$canonHeaders$resource',
    ].join('\n');
  }

  String signString(String s) => base64Encode(hmacSha256(_key, utf8.encode(s)));

  /// Authorization header value for the request.
  String authorization(String method, Uri uri, Map<String, String> headers) =>
      'SharedKey $accountName:${signString(stringToSign(method, uri, headers))}';

  /// Service SAS (read by default) for a blob, signed with the account key.
  String blobSas({
    required String container,
    required String blob,
    required DateTime expiry,
    String permissions = 'r',
    DateTime? start,
    String version = '2022-11-02',
  }) {
    final se = isoSeconds(expiry);
    final st = start == null ? '' : isoSeconds(start);
    final resource = '/blob/$accountName/$container/$blob';
    final sts = [
      permissions, st, se, resource, '', '', 'https', version, 'b', '', '', '', '', '', '', '', //
    ].join('\n');
    final sig = signString(sts);
    return canonicalQuery({
      'sv': version,
      if (st.isNotEmpty) 'st': st,
      'se': se,
      'sr': 'b',
      'sp': permissions,
      'spr': 'https',
      'sig': sig,
    });
  }
}

/// User delegation key returned by `Get User Delegation Key` (Entra ID).
class AzureUserDelegationKey {
  const AzureUserDelegationKey({
    required this.oid,
    required this.tid,
    required this.start,
    required this.expiry,
    required this.service,
    required this.version,
    required this.value,
  });
  final String oid;
  final String tid;
  final String start;
  final String expiry;
  final String service;
  final String version;
  final String value;

  /// User delegation SAS for a blob.
  String blobSas({
    required String account,
    required String container,
    required String blob,
    required DateTime expiry,
    String permissions = 'r',
    String version = '2022-11-02',
  }) {
    final se = isoSeconds(expiry);
    final resource = '/blob/$account/$container/$blob';
    final sts = [
      permissions, '', se, resource, oid, tid, start, this.expiry, service, this.version, //
      '', '', '', '', 'https', version, 'b', '', '', '', '', '', '', '',
    ].join('\n');
    final sig = base64Encode(hmacSha256(base64Decode(value), utf8.encode(sts)));
    return canonicalQuery({
      'sv': version,
      'se': se,
      'sr': 'b',
      'sp': permissions,
      'spr': 'https',
      'skoid': oid,
      'sktid': tid,
      'skt': start,
      'ske': this.expiry,
      'sks': service,
      'skv': this.version,
      'sig': sig,
    });
  }
}
