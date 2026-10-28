// Object storage accounts (S3 and compatible, Azure Blob, Google Cloud
// Storage) used by the Storage panel.
//
// Non secret settings live in `<workspace>/storage_accounts.json`; keys,
// tokens and client secrets are stored in the vault under `cloud:<id>:`
// (prefix kept from before the rename, so existing secrets stay valid).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../cloud/auth/aws_auth.dart';
import '../cloud/auth/azure_auth.dart';
import '../cloud/auth/gcp_auth.dart';
import '../cloud/cloud_common.dart';
import '../services/vault.dart';
import '../state/app_state.dart';
import 'backends/azure_blob_storage.dart';
import 'backends/gcs_storage.dart';
import 'backends/object_storage.dart';
import 'backends/s3_storage.dart';

export 'backends/object_storage.dart' show StorageProvider;

/// How an account authenticates.
enum StorageAuthKind {
  awsProfile(StorageProvider.aws, 'Profilo AWS (~/.aws)'),
  awsKeys(StorageProvider.aws, 'Chiavi di accesso'),
  awsDefault(StorageProvider.aws, 'Catena predefinita (ambiente, profilo, EC2)'),
  azureCli(StorageProvider.azure, 'Azure CLI (az login)'),
  azureSharedKey(StorageProvider.azure, 'Chiave dell\'account di archiviazione'),
  azureSas(StorageProvider.azure, 'Token SAS'),
  azureConnectionString(StorageProvider.azure, 'Stringa di connessione'),
  azureServicePrincipal(StorageProvider.azure, 'Service principal (client secret)'),
  azureManagedIdentity(StorageProvider.azure, 'Managed identity'),
  gcpServiceAccount(StorageProvider.gcp, 'Chiave di service account (JSON)'),
  gcpDefault(StorageProvider.gcp, 'Credenziali predefinite (ADC / gcloud)'),
  gcpToken(StorageProvider.gcp, 'Access token');

  const StorageAuthKind(this.provider, this.label);
  final StorageProvider provider;
  final String label;

  static List<StorageAuthKind> forProvider(StorageProvider p) => values.where((k) => k.provider == p).toList();

  static StorageAuthKind byName(String? n, StorageProvider p) =>
      values.firstWhere((k) => k.name == n, orElse: () => forProvider(p).first);
}

/// Field keys (non secret, saved in storage_accounts.json).
abstract final class StorageField {
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
abstract final class StorageSecret {
  static const secretAccessKey = 'secretAccessKey';
  static const sessionToken = 'sessionToken';
  static const accountKey = 'accountKey';
  static const sas = 'sas';
  static const connectionString = 'connectionString';
  static const clientSecret = 'clientSecret';
  static const keyJson = 'keyJson';
  static const token = 'token';
}

class StorageAccount {
  StorageAccount({
    String? id,
    required this.name,
    required this.provider,
    required this.authKind,
    Map<String, String>? fields,
  }) : id = id ?? _newId(),
       fields = fields ?? {};

  final String id;
  String name;
  StorageProvider provider;
  StorageAuthKind authKind;

  /// Non secret settings (see [StorageField]).
  Map<String, String> fields;

  static String _newId() {
    final r = Random.secure();
    return 'c${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${r.nextInt(1 << 30).toRadixString(36)}';
  }

  String field(String key) => (fields[key] ?? '').trim();

  bool get pathStyle => const {'true', '1', 'yes'}.contains(field(StorageField.pathStyle).toLowerCase());

  /// Short description shown under the account name.
  String get subtitle {
    final parts = <String>[];
    switch (provider) {
      case StorageProvider.aws:
        if (field(StorageField.endpoint).isNotEmpty) parts.add(Uri.tryParse(field(StorageField.endpoint))?.host ?? '');
        if (field(StorageField.region).isNotEmpty) parts.add(field(StorageField.region));
        if (authKind == StorageAuthKind.awsProfile) {
          parts.add('profilo ${field(StorageField.profile).isEmpty ? 'default' : field(StorageField.profile)}');
        }
      case StorageProvider.azure:
        if (field(StorageField.storageAccount).isNotEmpty) parts.add(field(StorageField.storageAccount));
      case StorageProvider.gcp:
        if (field(StorageField.project).isNotEmpty) parts.add(field(StorageField.project));
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

  factory StorageAccount.fromJson(Map<String, Object?> j) {
    final provider = StorageProvider.values.firstWhere((p) => p.name == j['provider'], orElse: () => StorageProvider.aws);
    return StorageAccount(
      id: j['id'] as String?,
      name: (j['name'] as String?) ?? 'Account',
      provider: provider,
      authKind: StorageAuthKind.byName(j['auth'] as String?, provider),
      fields: ((j['fields'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
    );
  }

  StorageAccount copy() =>
      StorageAccount(id: id, name: name, provider: provider, authKind: authKind, fields: Map.of(fields));
}

/// Builds the storage client of an account.
Future<ObjectStorage> createObjectStorage(StorageAccount a, Map<String, String> secrets) async {
  String s(String k) => (secrets[k] ?? '').trim();
  String f(String k) => a.field(k);
  String? opt(String v) => v.isEmpty ? null : v;
  switch (a.authKind) {
    case StorageAuthKind.awsKeys:
    case StorageAuthKind.awsProfile:
    case StorageAuthKind.awsDefault:
      final auth = AwsAuth(
        accessKeyId: a.authKind == StorageAuthKind.awsKeys ? f(StorageField.accessKeyId) : null,
        secretAccessKey: a.authKind == StorageAuthKind.awsKeys ? s(StorageSecret.secretAccessKey) : null,
        sessionToken: a.authKind == StorageAuthKind.awsKeys ? s(StorageSecret.sessionToken) : null,
        profile: a.authKind == StorageAuthKind.awsProfile ? (opt(f(StorageField.profile)) ?? 'default') : null,
        region: opt(f(StorageField.region)),
      );
      if (a.authKind == StorageAuthKind.awsKeys && f(StorageField.accessKeyId).isEmpty) {
        throw CloudException('Indica l\'access key ID.');
      }
      return S3Storage(
        auth: auth,
        region: opt(f(StorageField.region)),
        endpoint: opt(f(StorageField.endpoint)),
        pathStyle: a.pathStyle,
      );
    case StorageAuthKind.azureConnectionString:
      if (s(StorageSecret.connectionString).isEmpty) throw CloudException('Indica la stringa di connessione.');
      return AzureBlobStorage.fromConnectionString(s(StorageSecret.connectionString));
    case StorageAuthKind.azureCli:
    case StorageAuthKind.azureSharedKey:
    case StorageAuthKind.azureSas:
    case StorageAuthKind.azureServicePrincipal:
    case StorageAuthKind.azureManagedIdentity:
      final account = f(StorageField.storageAccount);
      if (account.isEmpty) throw CloudException('Indica il nome dello storage account.');
      final endpoint =
          opt(f(StorageField.endpoint)) ??
          'https://$account.blob.${opt(f(StorageField.endpointSuffix)) ?? 'core.windows.net'}';
      return AzureBlobStorage(
        endpoint: endpoint,
        accountName: account,
        sharedKey: a.authKind == StorageAuthKind.azureSharedKey
            ? (s(StorageSecret.accountKey).isEmpty
                  ? throw CloudException('Indica la chiave dello storage account.')
                  : AzureSharedKey(account, s(StorageSecret.accountKey)))
            : null,
        sas: a.authKind == StorageAuthKind.azureSas ? s(StorageSecret.sas) : null,
        credential: switch (a.authKind) {
          StorageAuthKind.azureCli => AzureCliCredential(tenantId: opt(f(StorageField.tenantId))),
          StorageAuthKind.azureServicePrincipal => AzureClientSecretCredential(
            tenantId: f(StorageField.tenantId),
            clientId: f(StorageField.clientId),
            clientSecret: s(StorageSecret.clientSecret),
          ),
          StorageAuthKind.azureManagedIdentity => AzureManagedIdentityCredential(clientId: opt(f(StorageField.clientId))),
          _ => null,
        },
      );
    case StorageAuthKind.gcpServiceAccount:
      final GcpCredential cred;
      if (s(StorageSecret.keyJson).isNotEmpty) {
        try {
          cred = gcpCredentialFromJson((jsonDecode(s(StorageSecret.keyJson)) as Map).cast<String, Object?>());
        } on CloudException {
          rethrow;
        } catch (_) {
          throw CloudException('Il JSON della chiave del service account non è valido.');
        }
      } else if (f(StorageField.keyFile).isNotEmpty) {
        cred = await gcpCredentialFromFile(f(StorageField.keyFile));
      } else {
        throw CloudException('Indica il file JSON della chiave del service account.');
      }
      return GcsStorage(credential: cred, project: opt(f(StorageField.project)));
    case StorageAuthKind.gcpDefault:
      return GcsStorage(credential: GcpDefaultCredential(), project: opt(f(StorageField.project)));
    case StorageAuthKind.gcpToken:
      if (s(StorageSecret.token).isEmpty) throw CloudException('Indica l\'access token.');
      return GcsStorage(
        credential: GcpStaticTokenCredential(s(StorageSecret.token)),
        project: opt(f(StorageField.project)),
      );
  }
}

/// Persistent list of storage accounts.
class StorageAccountsStore extends ChangeNotifier {
  StorageAccountsStore(this.root, this.vault);

  final Directory root;
  final Vault vault;
  final List<StorageAccount> accounts = [];
  final Map<String, ObjectStorage> _clients = {};
  bool _loaded = false;

  static final Expando<StorageAccountsStore> _byApp = Expando();

  /// Store of the workspace of [app] (created and loaded on first use).
  static StorageAccountsStore of(AppState app) {
    final existing = _byApp[app];
    if (existing != null) return existing;
    final s = StorageAccountsStore(app.workspace.root, app.vault);
    _byApp[app] = s;
    s.load();
    return s;
  }

  bool get isLoaded => _loaded;

  File get _file => File(p.join(root.path, 'storage_accounts.json'));

  /// Folder of the local copies of objects opened in the editor.
  static const localCopiesDir = 'storage';

  /// Moves the files of the "Cloud" era (cloud_accounts.json, cloud/) to
  /// their new names, unless the new ones already exist.
  Future<void> _migrateLegacyPaths() async {
    try {
      final legacyFile = File(p.join(root.path, 'cloud_accounts.json'));
      if (!await _file.exists() && await legacyFile.exists()) await legacyFile.rename(_file.path);
      final legacyDir = Directory(p.join(root.path, 'cloud'));
      final dir = Directory(p.join(root.path, localCopiesDir));
      if (!await dir.exists() && await legacyDir.exists()) await legacyDir.rename(dir.path);
    } catch (e) {
      debugPrint('Migrazione di cloud_accounts.json / cloud/ non riuscita: $e');
    }
  }

  static String secretPrefix(String id) => 'cloud:$id:';

  Future<void> load() async {
    accounts.clear();
    await _migrateLegacyPaths();
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString());
        final list = j is Map ? (j['accounts'] as List? ?? const []) : (j is List ? j : const []);
        for (final a in list) {
          accounts.add(StorageAccount.fromJson((a as Map).cast<String, Object?>()));
        }
      }
    } catch (e) {
      debugPrint('storage_accounts.json non leggibile: $e');
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

  Map<String, String> secrets(StorageAccount a) => vault.isLocked ? const {} : vault.withPrefix(secretPrefix(a.id));

  Future<void> add(StorageAccount a, Map<String, String> secrets) async {
    accounts.add(a);
    await vault.setAll(secretPrefix(a.id), secrets);
    await save();
    notifyListeners();
  }

  Future<void> update(StorageAccount a, Map<String, String> secrets) async {
    final i = accounts.indexWhere((e) => e.id == a.id);
    if (i < 0) return add(a, secrets);
    accounts[i] = a;
    _clients.remove(a.id)?.close();
    await vault.setAll(secretPrefix(a.id), secrets);
    await save();
    notifyListeners();
  }

  Future<void> remove(StorageAccount a) async {
    accounts.removeWhere((e) => e.id == a.id);
    _clients.remove(a.id)?.close();
    await vault.removePrefix(secretPrefix(a.id));
    await save();
    notifyListeners();
  }

  StorageAccount? byId(String id) {
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Storage client of [a] (cached until the account changes).
  Future<ObjectStorage> storage(StorageAccount a) async {
    final c = _clients[a.id];
    if (c != null) return c;
    return _clients[a.id] = await createObjectStorage(a, secrets(a));
  }

  /// Drops cached clients (credentials are resolved again).
  void resetClients() {
    for (final c in _clients.values) {
      c.close();
    }
    _clients.clear();
  }
}
