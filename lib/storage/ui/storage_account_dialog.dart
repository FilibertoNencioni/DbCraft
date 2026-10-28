// New / edit cloud account sheet (AWS, Azure, Google Cloud) with a test
// button that lists the buckets / containers.
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../cloud/auth/aws_auth.dart';
import '../../cloud/cloud_common.dart';
import '../../state/app_state.dart';
import '../../ui/widgets/common.dart';
import '../storage_accounts.dart';

/// Shows the account sheet and saves the result in the workspace store.
/// Returns the saved account, or null when cancelled.
Future<StorageAccount?> showStorageAccountDialog(BuildContext context, {StorageAccount? existing}) {
  final store = StorageAccountsStore.of(AppScope.read(context));
  return showSheet<StorageAccount>(
    context,
    builder: (_) => _StorageAccountDialog(store: store, existing: existing),
  );
}

IconData storageProviderIcon(StorageProvider p) => switch (p) {
  StorageProvider.aws => AppIcons.storage,
  StorageProvider.azure => AppIcons.storage,
  StorageProvider.gcp => AppIcons.storage,
};

Color storageProviderColor(StorageProvider p) => switch (p) {
  StorageProvider.aws => const Color(0xFFFF9900),
  StorageProvider.azure => const Color(0xFF0078D4),
  StorageProvider.gcp => const Color(0xFF4285F4),
};

String _authHelp(StorageAuthKind k) => switch (k) {
  StorageAuthKind.awsKeys => 'Le chiavi vengono salvate cifrate nel vault di DbCraft.',
  StorageAuthKind.awsProfile =>
    'Usa ~/.aws/credentials e ~/.aws/config: chiavi, credential_process, assume role e SSO (con AWS CLI v2).',
  StorageAuthKind.awsDefault =>
    'Variabili AWS_ACCESS_KEY_ID/AWS_PROFILE, profilo "default", credenziali del container o dell\'istanza EC2.',
  StorageAuthKind.azureCli => 'Usa il token di "az login". Ruolo richiesto: Storage Blob Data Reader o superiore.',
  StorageAuthKind.azureSharedKey => 'Chiave di accesso dello storage account (Chiavi di accesso nel portale).',
  StorageAuthKind.azureSas => 'Token SAS a livello di account o di container (sp con almeno r e l).',
  StorageAuthKind.azureConnectionString => 'DefaultEndpointsProtocol=https;AccountName=…;AccountKey=… oppure SAS.',
  StorageAuthKind.azureServicePrincipal =>
    'App registrata in Entra ID con un ruolo Storage Blob Data sullo storage account.',
  StorageAuthKind.azureManagedIdentity => 'Disponibile solo quando DbCraft è in esecuzione su una risorsa Azure.',
  StorageAuthKind.gcpServiceAccount => 'File JSON scaricato dalla console (IAM › Service account › Chiavi).',
  StorageAuthKind.gcpDefault =>
    'GOOGLE_APPLICATION_CREDENTIALS, "gcloud auth application-default login", gcloud CLI o server dei metadati.',
  StorageAuthKind.gcpToken => 'Token OAuth2 temporaneo (es. gcloud auth print-access-token): scade dopo un\'ora.',
};

class _StorageAccountDialog extends StatefulWidget {
  const _StorageAccountDialog({required this.store, this.existing});
  final StorageAccountsStore store;
  final StorageAccount? existing;

  @override
  State<_StorageAccountDialog> createState() => _StorageAccountDialogState();
}

class _StorageAccountDialogState extends State<_StorageAccountDialog> {
  late final StorageAccount _a =
      widget.existing?.copy() ??
      StorageAccount(name: '', provider: StorageProvider.aws, authKind: StorageAuthKind.awsProfile);
  final _name = TextEditingController();
  final Map<String, TextEditingController> _fields = {};
  final Map<String, TextEditingController> _secrets = {};
  bool _testing = false;
  String? _testOk;
  Object? _testError;
  List<String> _profiles = const [];

  @override
  void initState() {
    super.initState();
    _name.text = _a.name;
    _a.fields.forEach((k, v) => _f(k).text = v);
    widget.store.secrets(_a).forEach((k, v) => _s(k).text = v);
    AwsAuth.listProfiles().then((p) {
      if (mounted) setState(() => _profiles = p);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _name.dispose();
    for (final c in [..._fields.values, ..._secrets.values]) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _f(String k) => _fields.putIfAbsent(k, TextEditingController.new);
  TextEditingController _s(String k) => _secrets.putIfAbsent(k, TextEditingController.new);

  String _autoName() {
    final f = _f(_a.provider == StorageProvider.azure ? StorageField.storageAccount : StorageField.project).text.trim();
    return switch (_a.provider) {
      StorageProvider.aws =>
        _f(StorageField.endpoint).text.trim().isNotEmpty
            ? 'S3 ${Uri.tryParse(_f(StorageField.endpoint).text.trim())?.host ?? ''}'.trim()
            : 'AWS ${_a.authKind == StorageAuthKind.awsProfile ? (_f(StorageField.profile).text.trim().isEmpty ? 'default' : _f(StorageField.profile).text.trim()) : ''}'
                  .trim(),
      StorageProvider.azure => f.isEmpty ? 'Azure Storage' : f,
      StorageProvider.gcp => f.isEmpty ? 'Google Cloud Storage' : 'GCS $f',
    };
  }

  /// Fields relevant to the selected provider / method.
  List<String> get _fieldKeys => switch (_a.authKind) {
    StorageAuthKind.awsKeys => [StorageField.accessKeyId, StorageField.region, StorageField.endpoint, StorageField.pathStyle],
    StorageAuthKind.awsProfile => [StorageField.profile, StorageField.region, StorageField.endpoint, StorageField.pathStyle],
    StorageAuthKind.awsDefault => [StorageField.region, StorageField.endpoint, StorageField.pathStyle],
    StorageAuthKind.azureCli => [StorageField.storageAccount, StorageField.tenantId, StorageField.endpointSuffix],
    StorageAuthKind.azureSharedKey || StorageAuthKind.azureSas => [StorageField.storageAccount, StorageField.endpointSuffix],
    StorageAuthKind.azureConnectionString => const [],
    StorageAuthKind.azureServicePrincipal => [
      StorageField.storageAccount,
      StorageField.tenantId,
      StorageField.clientId,
      StorageField.endpointSuffix,
    ],
    StorageAuthKind.azureManagedIdentity => [StorageField.storageAccount, StorageField.clientId, StorageField.endpointSuffix],
    StorageAuthKind.gcpServiceAccount => [StorageField.keyFile, StorageField.project],
    StorageAuthKind.gcpDefault || StorageAuthKind.gcpToken => [StorageField.project],
  };

  List<String> get _secretKeys => switch (_a.authKind) {
    StorageAuthKind.awsKeys => [StorageSecret.secretAccessKey, StorageSecret.sessionToken],
    StorageAuthKind.azureSharedKey => [StorageSecret.accountKey],
    StorageAuthKind.azureSas => [StorageSecret.sas],
    StorageAuthKind.azureConnectionString => [StorageSecret.connectionString],
    StorageAuthKind.azureServicePrincipal => [StorageSecret.clientSecret],
    StorageAuthKind.gcpServiceAccount => [StorageSecret.keyJson],
    StorageAuthKind.gcpToken => [StorageSecret.token],
    _ => const [],
  };

  (StorageAccount, Map<String, String>) _collect() {
    final a = StorageAccount(
      id: _a.id,
      name: _name.text.trim().isEmpty ? _autoName() : _name.text.trim(),
      provider: _a.provider,
      authKind: _a.authKind,
      fields: {
        for (final k in _fieldKeys)
          if (k == StorageField.pathStyle) k: _a.pathStyle ? 'true' : '' else k: _f(k).text.trim(),
      },
    );
    final secrets = {for (final k in _secretKeys) k: _s(k).text.trim()};
    return (a, secrets);
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testOk = null;
      _testError = null;
    });
    try {
      final (a, secrets) = _collect();
      final storage = await createObjectStorage(a, secrets);
      final buckets = await storage.listBuckets().timeout(const Duration(seconds: 45));
      final term = a.provider.bucketTerm.toLowerCase();
      _testOk = buckets.isEmpty
          ? 'Accesso riuscito: nessun $term'
          : 'Accesso riuscito: ${buckets.length} ${buckets.length == 1 ? term : (a.provider == StorageProvider.azure ? 'container' : 'bucket')}';
    } on TimeoutException {
      _testError = CloudException('Nessuna risposta entro 45 secondi.');
    } catch (e) {
      _testError = e;
    }
    if (mounted) setState(() => _testing = false);
  }

  Future<void> _save() async {
    final (a, secrets) = _collect();
    final ok = await guarded(context, () async {
      if (widget.existing == null) {
        await widget.store.add(a, secrets);
      } else {
        await widget.store.update(a, secrets);
      }
    }, title: 'Salvataggio non riuscito');
    if (ok && mounted) Navigator.pop(context, a);
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SheetScaffold(
      title: widget.existing == null ? 'Nuovo account storage' : 'Modifica account storage',
      onSubmit: _save,
      leading: [
        PushButton(label: 'Prova', onPressed: _testing ? null : _test),
        Flexible(child: _status()),
      ],
      actions: [
        PushButton(label: 'Annulla', onPressed: () => Navigator.pop(context)),
        PushButton.primary(label: widget.existing == null ? 'Aggiungi' : 'Salva', onPressed: _save),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGroup(
            children: [
              FormRow(label: 'Nome', child: _field(_name, _autoName())),
              FormRow(
                label: 'Provider',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Segmented<StorageProvider>(
                    value: _a.provider,
                    items: const [
                      (StorageProvider.aws, 'AWS', null),
                      (StorageProvider.azure, 'Azure', null),
                      (StorageProvider.gcp, 'Google Cloud', null),
                    ],
                    onChanged: widget.existing != null
                        ? (_) {}
                        : (p) => setState(() {
                            _a.provider = p;
                            _a.authKind = StorageAuthKind.forProvider(p).first;
                            _testOk = null;
                            _testError = null;
                          }),
                  ),
                ),
              ),
            ],
          ),
          FormGroup(
            title: 'Autenticazione',
            footer: _authHelp(_a.authKind),
            children: [
              FormRow(
                label: 'Metodo',
                child: SelectField<StorageAuthKind>(
                  value: _a.authKind,
                  items: [for (final k in StorageAuthKind.forProvider(_a.provider)) (k, k.label, null)],
                  onChanged: (k) => setState(() {
                    _a.authKind = k;
                    _testOk = null;
                    _testError = null;
                  }),
                ),
              ),
              for (final k in _fieldKeys.where(_isAuthField)) _fieldRow(k),
              for (final k in _secretKeys) _secretRow(k),
            ],
          ),
          if (_fieldKeys.any((k) => !_isAuthField(k)))
            FormGroup(
              title: _a.provider == StorageProvider.aws ? 'Endpoint' : 'Risorsa',
              footer: _a.provider == StorageProvider.aws
                  ? 'Lascia vuoto l\'endpoint per Amazon S3; per MinIO, Cloudflare R2, Wasabi… indica l\'URL '
                        'del servizio e di solito attiva lo stile path.'
                  : null,
              children: [for (final k in _fieldKeys.where((k) => !_isAuthField(k))) _fieldRow(k)],
            ),
        ],
      ),
    );
  }

  bool _isAuthField(String k) => const {
    StorageField.accessKeyId,
    StorageField.profile,
    StorageField.tenantId,
    StorageField.clientId,
    StorageField.keyFile,
  }.contains(k);

  Widget _status() {
    if (_testing) return const StatusLine.busy('Verifica in corso…');
    if (_testOk != null) return StatusLine(_testOk!, kind: StatusKind.success, maxLines: 1);
    if (_testError != null) {
      return StatusLine(
        _testError.toString().split('\n').first,
        kind: StatusKind.danger,
        maxLines: 1,
        onDetails: () => showErrorDialog(context, _testError!, title: 'Accesso non riuscito'),
      );
    }
    return const SizedBox.shrink();
  }

  void _clearTest() => setState(() {
    _testOk = null;
    _testError = null;
  });

  Widget _field(TextEditingController ctrl, String hint) =>
      MacTextField(controller: ctrl, hint: hint, onChanged: (_) => _clearTest());

  Widget _fieldRow(String k) {
    switch (k) {
      case StorageField.pathStyle:
        return FormRow(
          label: 'Stile path',
          help: 'bucket nel percorso dell\'URL',
          child: Align(
            alignment: Alignment.centerLeft,
            child: DbSwitch(
              value: _a.pathStyle,
              onChanged: (v) => setState(() => _a.fields[StorageField.pathStyle] = v ? 'true' : ''),
            ),
          ),
        );
      case StorageField.profile:
        return FormRow(
          label: 'Profilo',
          child: _profiles.isEmpty
              ? _field(_f(k), 'default')
              : ComboField(
                  controller: _f(k),
                  options: () => _profiles,
                  hint: 'default',
                  onChanged: (_) => _clearTest(),
                ),
        );
      case StorageField.keyFile:
        return FormRow(
          label: 'File chiave JSON',
          child: PathField(
            controller: _f(k),
            hint: 'Percorso del file .json',
            onChanged: (_) => _clearTest(),
            onChoose: () async {
              final f = await openFile(
                acceptedTypeGroups: const [
                  XTypeGroup(label: 'JSON', extensions: ['json']),
                ],
              );
              if (f != null) setState(() => _f(k).text = f.path);
            },
          ),
        );
    }
    final (label, hint, help) = switch (k) {
      StorageField.accessKeyId => ('Access key ID', 'AKIA…', null),
      StorageField.region => ('Regione', 'eu-west-1 (vuoto = dal profilo)', null),
      StorageField.endpoint => (
        'Endpoint',
        _a.provider == StorageProvider.aws ? 'https://s3.example.com (facoltativo)' : 'https://… (facoltativo)',
        null,
      ),
      StorageField.storageAccount => ('Storage account', 'nomeaccount', null),
      StorageField.endpointSuffix => ('Suffisso endpoint', 'core.windows.net', 'cloud sovrani'),
      StorageField.tenantId => (
        'Tenant ID',
        _a.authKind == StorageAuthKind.azureCli ? 'Facoltativo' : '00000000-0000-…',
        null,
      ),
      StorageField.clientId => (
        'Client ID',
        _a.authKind == StorageAuthKind.azureManagedIdentity ? 'Solo identità assegnate dall\'utente' : 'ID applicazione',
        null,
      ),
      StorageField.project => (
        'Progetto',
        _a.authKind == StorageAuthKind.gcpServiceAccount ? 'Vuoto = progetto della chiave' : 'ID progetto',
        null,
      ),
      _ => (k, '', null),
    };
    return FormRow(label: label, help: help, child: _field(_f(k), hint));
  }

  Widget _secretRow(String k) {
    final (label, hint, multiline) = switch (k) {
      StorageSecret.secretAccessKey => ('Secret access key', '', false),
      StorageSecret.sessionToken => ('Session token', 'Facoltativo (credenziali temporanee)', false),
      StorageSecret.accountKey => ('Chiave account', 'Base64', false),
      StorageSecret.sas => ('Token SAS', 'sv=…&ss=b&srt=…&sp=rl&sig=…', false),
      StorageSecret.connectionString => ('Stringa di connessione', 'DefaultEndpointsProtocol=https;AccountName=…', true),
      StorageSecret.clientSecret => ('Client secret', '', false),
      StorageSecret.keyJson => ('Oppure JSON', 'Incolla o scegli il file della chiave (salvata nel vault)', true),
      StorageSecret.token => ('Access token', 'ya29.…', false),
      _ => (k, '', false),
    };
    // Multi-line secrets stay on one masked line until revealed, then grow to four.
    return FormRow(
      label: label,
      child: SecureField(
        controller: _s(k),
        hint: hint,
        maxLines: multiline ? 4 : 1,
        onChanged: (_) => _clearTest(),
        onChoose: k == StorageSecret.keyJson ? () => _loadSecret(k) : null,
        chooseTooltip: 'Carica il contenuto da un file .json',
      ),
    );
  }

  /// Reads a JSON key file into the secret [k] (stored in the vault).
  Future<void> _loadSecret(String k) async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (f == null) return;
    final text = await f.readAsString();
    if (!mounted) return;
    _s(k).text = text.trim();
    _clearTest();
  }
}
