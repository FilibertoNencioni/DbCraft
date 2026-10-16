// New / edit cloud account sheet (AWS, Azure, Google Cloud) with a test
// button that lists the buckets / containers.
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../ui/widgets/common.dart';
import '../auth/aws_auth.dart';
import '../cloud_accounts.dart';
import '../cloud_common.dart';

/// Shows the account sheet and saves the result in the workspace store.
/// Returns the saved account, or null when cancelled.
Future<CloudAccount?> showCloudAccountDialog(BuildContext context, {CloudAccount? existing}) {
  final store = CloudAccountsStore.of(AppScope.read(context));
  return showSheet<CloudAccount>(
    context,
    builder: (_) => _CloudAccountDialog(store: store, existing: existing),
  );
}

IconData cloudProviderIcon(CloudProvider p) => switch (p) {
  CloudProvider.aws => AppIcons.cloud,
  CloudProvider.azure => AppIcons.cloud,
  CloudProvider.gcp => AppIcons.cloud,
};

Color cloudProviderColor(CloudProvider p) => switch (p) {
  CloudProvider.aws => const Color(0xFFFF9900),
  CloudProvider.azure => const Color(0xFF0078D4),
  CloudProvider.gcp => const Color(0xFF4285F4),
};

String _authHelp(CloudAuthKind k) => switch (k) {
  CloudAuthKind.awsKeys => 'Le chiavi vengono salvate cifrate nel vault di DbCraft.',
  CloudAuthKind.awsProfile =>
    'Usa ~/.aws/credentials e ~/.aws/config: chiavi, credential_process, assume role e SSO (con AWS CLI v2).',
  CloudAuthKind.awsDefault =>
    'Variabili AWS_ACCESS_KEY_ID/AWS_PROFILE, profilo "default", credenziali del container o dell\'istanza EC2.',
  CloudAuthKind.azureCli => 'Usa il token di "az login". Ruolo richiesto: Storage Blob Data Reader o superiore.',
  CloudAuthKind.azureSharedKey => 'Chiave di accesso dello storage account (Chiavi di accesso nel portale).',
  CloudAuthKind.azureSas => 'Token SAS a livello di account o di container (sp con almeno r e l).',
  CloudAuthKind.azureConnectionString => 'DefaultEndpointsProtocol=https;AccountName=…;AccountKey=… oppure SAS.',
  CloudAuthKind.azureServicePrincipal =>
    'App registrata in Entra ID con un ruolo Storage Blob Data sullo storage account.',
  CloudAuthKind.azureManagedIdentity => 'Disponibile solo quando DbCraft è in esecuzione su una risorsa Azure.',
  CloudAuthKind.gcpServiceAccount => 'File JSON scaricato dalla console (IAM › Service account › Chiavi).',
  CloudAuthKind.gcpDefault =>
    'GOOGLE_APPLICATION_CREDENTIALS, "gcloud auth application-default login", gcloud CLI o server dei metadati.',
  CloudAuthKind.gcpToken => 'Token OAuth2 temporaneo (es. gcloud auth print-access-token): scade dopo un\'ora.',
};

class _CloudAccountDialog extends StatefulWidget {
  const _CloudAccountDialog({required this.store, this.existing});
  final CloudAccountsStore store;
  final CloudAccount? existing;

  @override
  State<_CloudAccountDialog> createState() => _CloudAccountDialogState();
}

class _CloudAccountDialogState extends State<_CloudAccountDialog> {
  late final CloudAccount _a =
      widget.existing?.copy() ??
      CloudAccount(name: '', provider: CloudProvider.aws, authKind: CloudAuthKind.awsProfile);
  final _name = TextEditingController();
  final Map<String, TextEditingController> _fields = {};
  final Map<String, TextEditingController> _secrets = {};
  bool _showSecrets = false;
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
    final f = _f(_a.provider == CloudProvider.azure ? CloudField.storageAccount : CloudField.project).text.trim();
    return switch (_a.provider) {
      CloudProvider.aws =>
        _f(CloudField.endpoint).text.trim().isNotEmpty
            ? 'S3 ${Uri.tryParse(_f(CloudField.endpoint).text.trim())?.host ?? ''}'.trim()
            : 'AWS ${_a.authKind == CloudAuthKind.awsProfile ? (_f(CloudField.profile).text.trim().isEmpty ? 'default' : _f(CloudField.profile).text.trim()) : ''}'
                  .trim(),
      CloudProvider.azure => f.isEmpty ? 'Azure Storage' : f,
      CloudProvider.gcp => f.isEmpty ? 'Google Cloud Storage' : 'GCS $f',
    };
  }

  /// Fields relevant to the selected provider / method.
  List<String> get _fieldKeys => switch (_a.authKind) {
    CloudAuthKind.awsKeys => [CloudField.accessKeyId, CloudField.region, CloudField.endpoint, CloudField.pathStyle],
    CloudAuthKind.awsProfile => [CloudField.profile, CloudField.region, CloudField.endpoint, CloudField.pathStyle],
    CloudAuthKind.awsDefault => [CloudField.region, CloudField.endpoint, CloudField.pathStyle],
    CloudAuthKind.azureCli => [CloudField.storageAccount, CloudField.tenantId, CloudField.endpointSuffix],
    CloudAuthKind.azureSharedKey || CloudAuthKind.azureSas => [CloudField.storageAccount, CloudField.endpointSuffix],
    CloudAuthKind.azureConnectionString => const [],
    CloudAuthKind.azureServicePrincipal => [
      CloudField.storageAccount,
      CloudField.tenantId,
      CloudField.clientId,
      CloudField.endpointSuffix,
    ],
    CloudAuthKind.azureManagedIdentity => [CloudField.storageAccount, CloudField.clientId, CloudField.endpointSuffix],
    CloudAuthKind.gcpServiceAccount => [CloudField.keyFile, CloudField.project],
    CloudAuthKind.gcpDefault || CloudAuthKind.gcpToken => [CloudField.project],
  };

  List<String> get _secretKeys => switch (_a.authKind) {
    CloudAuthKind.awsKeys => [CloudSecret.secretAccessKey, CloudSecret.sessionToken],
    CloudAuthKind.azureSharedKey => [CloudSecret.accountKey],
    CloudAuthKind.azureSas => [CloudSecret.sas],
    CloudAuthKind.azureConnectionString => [CloudSecret.connectionString],
    CloudAuthKind.azureServicePrincipal => [CloudSecret.clientSecret],
    CloudAuthKind.gcpServiceAccount => [CloudSecret.keyJson],
    CloudAuthKind.gcpToken => [CloudSecret.token],
    _ => const [],
  };

  (CloudAccount, Map<String, String>) _collect() {
    final a = CloudAccount(
      id: _a.id,
      name: _name.text.trim().isEmpty ? _autoName() : _name.text.trim(),
      provider: _a.provider,
      authKind: _a.authKind,
      fields: {
        for (final k in _fieldKeys)
          if (k == CloudField.pathStyle) k: _a.pathStyle ? 'true' : '' else k: _f(k).text.trim(),
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
      final storage = await createCloudStorage(a, secrets);
      final buckets = await storage.listBuckets().timeout(const Duration(seconds: 45));
      final term = a.provider.bucketTerm.toLowerCase();
      _testOk = buckets.isEmpty
          ? 'Accesso riuscito: nessun $term'
          : 'Accesso riuscito: ${buckets.length} ${buckets.length == 1 ? term : (a.provider == CloudProvider.azure ? 'container' : 'bucket')}';
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
      title: widget.existing == null ? 'Nuovo account cloud' : 'Modifica account cloud',
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
                  child: Segmented<CloudProvider>(
                    value: _a.provider,
                    items: const [
                      (CloudProvider.aws, 'AWS', null),
                      (CloudProvider.azure, 'Azure', null),
                      (CloudProvider.gcp, 'Google Cloud', null),
                    ],
                    onChanged: widget.existing != null
                        ? (_) {}
                        : (p) => setState(() {
                            _a.provider = p;
                            _a.authKind = CloudAuthKind.forProvider(p).first;
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
                child: SelectField<CloudAuthKind>(
                  value: _a.authKind,
                  items: [for (final k in CloudAuthKind.forProvider(_a.provider)) (k, k.label, null)],
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
              title: _a.provider == CloudProvider.aws ? 'Endpoint' : 'Risorsa',
              footer: _a.provider == CloudProvider.aws
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
    CloudField.accessKeyId,
    CloudField.profile,
    CloudField.tenantId,
    CloudField.clientId,
    CloudField.keyFile,
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

  Widget _field(TextEditingController ctrl, String hint, {bool obscure = false, Widget? trailing, int maxLines = 1}) =>
      MacTextField(
        controller: ctrl,
        hint: hint,
        obscure: obscure,
        maxLines: obscure ? 1 : maxLines,
        minLines: 1,
        mono: maxLines > 1,
        trailing: trailing,
        onChanged: (_) => _clearTest(),
      );

  Widget _fieldRow(String k) {
    switch (k) {
      case CloudField.pathStyle:
        return FormRow(
          label: 'Stile path',
          help: 'bucket nel percorso dell\'URL',
          child: Align(
            alignment: Alignment.centerLeft,
            child: DbSwitch(
              value: _a.pathStyle,
              onChanged: (v) => setState(() => _a.fields[CloudField.pathStyle] = v ? 'true' : ''),
            ),
          ),
        );
      case CloudField.profile:
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
      case CloudField.keyFile:
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
      CloudField.accessKeyId => ('Access key ID', 'AKIA…', null),
      CloudField.region => ('Regione', 'eu-west-1 (vuoto = dal profilo)', null),
      CloudField.endpoint => (
        'Endpoint',
        _a.provider == CloudProvider.aws ? 'https://s3.example.com (facoltativo)' : 'https://… (facoltativo)',
        null,
      ),
      CloudField.storageAccount => ('Storage account', 'nomeaccount', null),
      CloudField.endpointSuffix => ('Suffisso endpoint', 'core.windows.net', 'cloud sovrani'),
      CloudField.tenantId => (
        'Tenant ID',
        _a.authKind == CloudAuthKind.azureCli ? 'Facoltativo' : '00000000-0000-…',
        null,
      ),
      CloudField.clientId => (
        'Client ID',
        _a.authKind == CloudAuthKind.azureManagedIdentity ? 'Solo identità assegnate dall\'utente' : 'ID applicazione',
        null,
      ),
      CloudField.project => (
        'Progetto',
        _a.authKind == CloudAuthKind.gcpServiceAccount ? 'Vuoto = progetto della chiave' : 'ID progetto',
        null,
      ),
      _ => (k, '', null),
    };
    return FormRow(label: label, help: help, child: _field(_f(k), hint));
  }

  Widget _secretRow(String k) {
    final (label, hint, multiline) = switch (k) {
      CloudSecret.secretAccessKey => ('Secret access key', '', false),
      CloudSecret.sessionToken => ('Session token', 'Facoltativo (credenziali temporanee)', false),
      CloudSecret.accountKey => ('Chiave account', 'Base64', false),
      CloudSecret.sas => ('Token SAS', 'sv=…&ss=b&srt=…&sp=rl&sig=…', false),
      CloudSecret.connectionString => ('Stringa di connessione', 'DefaultEndpointsProtocol=https;AccountName=…', true),
      CloudSecret.clientSecret => ('Client secret', '', false),
      CloudSecret.keyJson => ('Oppure JSON', 'Incolla il contenuto della chiave (salvato nel vault)', true),
      CloudSecret.token => ('Access token', 'ya29.…', false),
      _ => (k, '', false),
    };
    if (!multiline) {
      return FormRow(
        label: label,
        child: SecureField(controller: _s(k), hint: hint, onChanged: (_) => _clearTest()),
      );
    }
    // Multiline secrets are hidden on one line and edited on four once revealed:
    // SecureField is single-line only.
    final eye = Padding(
      padding: const EdgeInsets.only(right: 2),
      child: ToolButton(
        icon: _showSecrets ? AppIcons.eyeOff : AppIcons.eye,
        tooltip: _showSecrets ? 'Nascondi' : 'Mostra',
        extent: 18,
        onPressed: () => setState(() => _showSecrets = !_showSecrets),
      ),
    );
    return FormRow(
      label: label,
      help: !_showSecrets && _s(k).text.isNotEmpty ? 'Contenuto nascosto' : null,
      child: _field(_s(k), hint, obscure: !_showSecrets, maxLines: 4, trailing: eye),
    );
  }
}
