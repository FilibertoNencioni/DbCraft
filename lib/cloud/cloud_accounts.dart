// Cloud accounts (AWS, Azure, Google Cloud) used by the Cloud Explorer.
//
// Non secret settings live in `<workspace>/cloud_accounts.json`; keys,
// tokens and client secrets are stored in the vault under `cloud:<id>:`.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/vault.dart';
import '../state/app_state.dart';
import 'auth/aws_auth.dart';
import 'auth/azure_auth.dart';
import 'auth/gcp_auth.dart';
import 'cloud_common.dart';
import 'storage/azure_blob_storage.dart';
import 'storage/cloud_storage.dart';
import 'storage/gcs_storage.dart';
import 'storage/s3_storage.dart';

export 'storage/cloud_storage.dart' show CloudProvider;

/// How an account authenticates.
enum CloudAuthKind {
  awsProfile(CloudProvider.aws, 'Profilo AWS (~/.aws)'),
  awsKeys(CloudProvider.aws, 'Chiavi di accesso'),
  awsDefault(CloudProvider.aws, 'Catena predefinita (ambiente, profilo, EC2)'),
  azureCli(CloudProvider.azure, 'Azure CLI (az login)'),
  azureSharedKey(CloudProvider.azure, 'Chiave dell\'account di archiviazione'),
  azureSas(CloudProvider.azure, 'Token SAS'),
  azureConnectionString(CloudProvider.azure, 'Stringa di connessione'),
  azureServicePrincipal(CloudProvider.azure, 'Service principal (client secret)'),
  azureManagedIdentity(CloudProvider.azure, 'Managed identity'),
  gcpServiceAccount(CloudProvider.gcp, 'Chiave di service account (JSON)'),
  gcpDefault(CloudProvider.gcp, 'Credenziali predefinite (ADC / gcloud)'),
  gcpToken(CloudProvider.gcp, 'Access token');

  const CloudAuthKind(this.provider, this.label);
  final CloudProvider provider;
  final String label;

  static List<CloudAuthKind> forProvider(CloudProvider p) => values.where((k) => k.provider == p).toList();

  static CloudAuthKind byName(String? n, CloudProvider p) =>
      values.firstWhere((k) => k.name == n, orElse: () => forProvider(p).first);
}

/// Field keys (non secret, saved in cloud_accounts.json).
abstract final class CloudField {
  static const region = 'region';
  static const profile = 'profile';
  static const endpoint = 'endpoint';
  static const pathStyle = 'pathStyle';
  static const accessKeyId = 'accessKeyId';
  static const storageAccount = 'storageAccount';
  static const endpointSuffix = 'endpointSuffix';
  static const tenantId = 'tenantId';
  static const clientId = 'clientId';
  static const project = 'project';
  static const keyFile = 'keyFile';
}

/// Secret keys (vault).
abstract final class CloudSecret {
  static const secretAccessKey = 'secretAccessKey';
  static const sessionToken = 'sessionToken';
  static const accountKey = 'accountKey';
  static const sas = 'sas';
  static const connectionString = 'connectionString';
  static const clientSecret = 'clientSecret';
  static const keyJson = 'keyJson';
  static const token = 'token';
}

class CloudAccount {
  CloudAccount({
    String? id,
    required this.name,
    required this.provider,
    required this.authKind,
    Map<String, String>? fields,
  }) : id = id ?? _newId(),
       fields = fields ?? {};

  final String id;
  String name;
  CloudProvider provider;
  CloudAuthKind authKind;

  /// Non secret settings (see [CloudField]).
  Map<String, String> fields;

  static String _newId() {
    final r = Random.secure();
    return 'c${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${r.nextInt(1 << 30).toRadixString(36)}';
  }

  String field(String key) => (fields[key] ?? '').trim();

  bool get pathStyle => const {'true', '1', 'yes'}.contains(field(CloudField.pathStyle).toLowerCase());

  /// Short description shown under the account name.
  String get subtitle {
    final parts = <String>[];
    switch (provider) {
      case CloudProvider.aws:
        if (field(CloudField.endpoint).isNotEmpty) parts.add(Uri.tryParse(field(CloudField.endpoint))?.host ?? '');
        if (field(CloudField.region).isNotEmpty) parts.add(field(CloudField.region));
        if (authKind == CloudAuthKind.awsProfile) {
          parts.add('profilo ${field(CloudField.profile).isEmpty ? 'default' : field(CloudField.profile)}');
        }
      case CloudProvider.azure:
        if (field(CloudField.storageAccount).isNotEmpty) parts.add(field(CloudField.storageAccount));
      case CloudProvider.gcp:
        if (field(CloudField.project).isNotEmpty) parts.add(field(CloudField.project));
    }
    return parts.where((e) => e.isNotEmpty).join(' · ');
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'provider': provider.name,
    'auth': authKind.name,
    'fields': {
      for (final e in fields.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    },
  };

  factory CloudAccount.fromJson(Map<String, Object?> j) {
    final provider = CloudProvider.values.firstWhere((p) => p.name == j['provider'], orElse: () => CloudProvider.aws);
    return CloudAccount(
      id: j['id'] as String?,
      name: (j['name'] as String?) ?? 'Account',
      provider: provider,
      authKind: CloudAuthKind.byName(j['auth'] as String?, provider),
      fields: ((j['fields'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
    );
  }

  CloudAccount copy() =>
      CloudAccount(id: id, name: name, provider: provider, authKind: authKind, fields: Map.of(fields));
}

/// Builds the storage client of an account.
Future<CloudStorage> createCloudStorage(CloudAccount a, Map<String, String> secrets) async {
  String s(String k) => (secrets[k] ?? '').trim();
  String f(String k) => a.field(k);
  String? opt(String v) => v.isEmpty ? null : v;
  switch (a.authKind) {
    case CloudAuthKind.awsKeys:
    case CloudAuthKind.awsProfile:
    case CloudAuthKind.awsDefault:
      final auth = AwsAuth(
        accessKeyId: a.authKind == CloudAuthKind.awsKeys ? f(CloudField.accessKeyId) : null,
        secretAccessKey: a.authKind == CloudAuthKind.awsKeys ? s(CloudSecret.secretAccessKey) : null,
        sessionToken: a.authKind == CloudAuthKind.awsKeys ? s(CloudSecret.sessionToken) : null,
        profile: a.authKind == CloudAuthKind.awsProfile ? (opt(f(CloudField.profile)) ?? 'default') : null,
        region: opt(f(CloudField.region)),
      );
      if (a.authKind == CloudAuthKind.awsKeys && f(CloudField.accessKeyId).isEmpty) {
        throw CloudException('Indica l\'access key ID.');
      }
      return S3Storage(
        auth: auth,
        region: opt(f(CloudField.region)),
        endpoint: opt(f(CloudField.endpoint)),
        pathStyle: a.pathStyle,
      );
    case CloudAuthKind.azureConnectionString:
      if (s(CloudSecret.connectionString).isEmpty) throw CloudException('Indica la stringa di connessione.');
      return AzureBlobStorage.fromConnectionString(s(CloudSecret.connectionString));
    case CloudAuthKind.azureCli:
    case CloudAuthKind.azureSharedKey:
    case CloudAuthKind.azureSas:
    case CloudAuthKind.azureServicePrincipal:
    case CloudAuthKind.azureManagedIdentity:
      final account = f(CloudField.storageAccount);
      if (account.isEmpty) throw CloudException('Indica il nome dello storage account.');
      final endpoint =
          opt(f(CloudField.endpoint)) ??
          'https://$account.blob.${opt(f(CloudField.endpointSuffix)) ?? 'core.windows.net'}';
      return AzureBlobStorage(
        endpoint: endpoint,
        accountName: account,
        sharedKey: a.authKind == CloudAuthKind.azureSharedKey
            ? (s(CloudSecret.accountKey).isEmpty
                  ? throw CloudException('Indica la chiave dello storage account.')
                  : AzureSharedKey(account, s(CloudSecret.accountKey)))
            : null,
        sas: a.authKind == CloudAuthKind.azureSas ? s(CloudSecret.sas) : null,
        credential: switch (a.authKind) {
          CloudAuthKind.azureCli => AzureCliCredential(tenantId: opt(f(CloudField.tenantId))),
          CloudAuthKind.azureServicePrincipal => AzureClientSecretCredential(
            tenantId: f(CloudField.tenantId),
            clientId: f(CloudField.clientId),
            clientSecret: s(CloudSecret.clientSecret),
          ),
          CloudAuthKind.azureManagedIdentity => AzureManagedIdentityCredential(clientId: opt(f(CloudField.clientId))),
          _ => null,
        },
      );
    case CloudAuthKind.gcpServiceAccount:
      final GcpCredential cred;
      if (s(CloudSecret.keyJson).isNotEmpty) {
        try {
          cred = gcpCredentialFromJson((jsonDecode(s(CloudSecret.keyJson)) as Map).cast<String, Object?>());
        } on CloudException {
          rethrow;
        } catch (_) {
          throw CloudException('Il JSON della chiave del service account non è valido.');
        }
      } else if (f(CloudField.keyFile).isNotEmpty) {
        cred = await gcpCredentialFromFile(f(CloudField.keyFile));
      } else {
        throw CloudException('Indica il file JSON della chiave del service account.');
      }
      return GcsStorage(credential: cred, project: opt(f(CloudField.project)));
    case CloudAuthKind.gcpDefault:
      return GcsStorage(credential: GcpDefaultCredential(), project: opt(f(CloudField.project)));
    case CloudAuthKind.gcpToken:
      if (s(CloudSecret.token).isEmpty) throw CloudException('Indica l\'access token.');
      return GcsStorage(
        credential: GcpStaticTokenCredential(s(CloudSecret.token)),
        project: opt(f(CloudField.project)),
      );
  }
}

/// Persistent list of cloud accounts.
class CloudAccountsStore extends ChangeNotifier {
  CloudAccountsStore(this.root, this.vault);

  final Directory root;
  final Vault vault;
  final List<CloudAccount> accounts = [];
  final Map<String, CloudStorage> _clients = {};
  bool _loaded = false;

  static final Expando<CloudAccountsStore> _byApp = Expando();

  /// Store of the workspace of [app] (created and loaded on first use).
  static CloudAccountsStore of(AppState app) {
    final existing = _byApp[app];
    if (existing != null) return existing;
    final s = CloudAccountsStore(app.workspace.root, app.vault);
    _byApp[app] = s;
    s.load();
    return s;
  }

  bool get isLoaded => _loaded;

  File get _file => File(p.join(root.path, 'cloud_accounts.json'));

  static String secretPrefix(String id) => 'cloud:$id:';

  Future<void> load() async {
    accounts.clear();
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString());
        final list = j is Map ? (j['accounts'] as List? ?? const []) : (j is List ? j : const []);
        for (final a in list) {
          accounts.add(CloudAccount.fromJson((a as Map).cast<String, Object?>()));
        }
      }
    } catch (e) {
      debugPrint('cloud_accounts.json non leggibile: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'accounts': [for (final a in accounts) a.toJson()],
      }),
    );
    await tmp.rename(_file.path);
  }

  Map<String, String> secrets(CloudAccount a) => vault.isLocked ? const {} : vault.withPrefix(secretPrefix(a.id));

  Future<void> add(CloudAccount a, Map<String, String> secrets) async {
    accounts.add(a);
    await vault.setAll(secretPrefix(a.id), secrets);
    await save();
    notifyListeners();
  }

  Future<void> update(CloudAccount a, Map<String, String> secrets) async {
    final i = accounts.indexWhere((e) => e.id == a.id);
    if (i < 0) return add(a, secrets);
    accounts[i] = a;
    _clients.remove(a.id)?.close();
    await vault.setAll(secretPrefix(a.id), secrets);
    await save();
    notifyListeners();
  }

  Future<void> remove(CloudAccount a) async {
    accounts.removeWhere((e) => e.id == a.id);
    _clients.remove(a.id)?.close();
    await vault.removePrefix(secretPrefix(a.id));
    await save();
    notifyListeners();
  }

  CloudAccount? byId(String id) {
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Storage client of [a] (cached until the account changes).
  Future<CloudStorage> storage(CloudAccount a) async {
    final c = _clients[a.id];
    if (c != null) return c;
    return _clients[a.id] = await createCloudStorage(a, secrets(a));
  }

  /// Drops cached clients (credentials are resolved again).
  void resetClients() {
    for (final c in _clients.values) {
      c.close();
    }
    _clients.clear();
  }
}
