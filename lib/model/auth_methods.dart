// Enterprise authentication methods (Kerberos, Microsoft Entra ID, SSO/SAML,
// Okta, AWS IAM, OAuth, key pair).
//
// ODBC drivers implement these flows themselves: DbCraft translates the chosen
// method into the connection string attributes understood by each driver.
// Methods that need a token obtained beforehand (Entra ID for PostgreSQL and
// MySQL, AWS IAM for RDS) are resolved by services/auth_tokens.dart right
// before connecting.
import 'connection_config.dart';

enum AuthMethod {
  password('Utente e password', 'Credenziali del database'),
  none('Nessuna', 'Il driver non richiede credenziali'),
  kerberos('Kerberos / autenticazione integrata', 'Usa il ticket Kerberos (kinit) o l\'accesso Windows'),
  azureAdPassword('Microsoft Entra ID – password', 'Utente e password Entra ID (Azure AD)'),
  azureAdInteractive('Microsoft Entra ID – interattiva', 'Accesso nel browser con MFA'),
  azureAdIntegrated('Microsoft Entra ID – integrata', 'Account Windows/Kerberos federato'),
  azureAdServicePrincipal('Microsoft Entra ID – service principal', 'Client ID e secret di un\'app registrata'),
  azureAdManagedIdentity('Microsoft Entra ID – managed identity', 'Identità gestita della VM/App Service'),
  azureAdDefault('Microsoft Entra ID – Azure CLI / predefinita', 'Token di `az login` o variabili d\'ambiente'),
  ssoBrowser('SSO / SAML nel browser', 'Single sign-on con il provider di identità aziendale'),
  okta('Okta', 'Autenticazione nativa Okta'),
  gcpDefault('Google Cloud – gcloud / ADC', 'Credenziali predefinite dell\'applicazione o `gcloud auth`'),
  awsIam('AWS IAM', 'Profilo AWS / chiavi IAM al posto della password'),
  oauthToken('Token OAuth', 'Access token fornito dal provider'),
  keyPair('Coppia di chiavi', 'Chiave privata (JWT) al posto della password');

  const AuthMethod(this.label, this.description);
  final String label;
  final String description;

  bool get isAzure => name.startsWith('azureAd');

  /// The user name field is meaningful for this method.
  bool get usesUser => switch (this) {
    none || kerberos || azureAdIntegrated || azureAdManagedIdentity || gcpDefault => false,
    _ => true,
  };

  /// The password field is meaningful for this method.
  bool get usesPassword => switch (this) {
    password || azureAdPassword || okta => true,
    _ => false,
  };
}

/// Extra parameter of an authentication method (stored in authParams, or in
/// the vault when [secret]).
class AuthParam {
  const AuthParam(this.key, this.label, {this.hint = '', this.secret = false, this.file = false, this.help});
  final String key;
  final String label;
  final String hint;
  final bool secret;
  final bool file;
  final String? help;
}

/// Methods offered for a driver template / native driver id.
List<AuthMethod> supportedAuthMethods(ConnectionConfig c) {
  if (c.mode == ConnectionMode.native) {
    return switch (c.nativeDriver) {
      'mongodb' => const [AuthMethod.password, AuthMethod.none, AuthMethod.kerberos, AuthMethod.awsIam, AuthMethod.oauthToken],
      'redis' => const [AuthMethod.password, AuthMethod.none, AuthMethod.azureAdDefault, AuthMethod.awsIam],
      'cassandra' => const [AuthMethod.password, AuthMethod.none],
      'bigquery' => const [AuthMethod.keyPair, AuthMethod.gcpDefault, AuthMethod.oauthToken],
      _ => const [AuthMethod.password, AuthMethod.none],
    };
  }
  final t = c.template;
  return switch (t.id) {
    'sqlserver' => const [
      AuthMethod.password,
      AuthMethod.kerberos,
      AuthMethod.azureAdPassword,
      AuthMethod.azureAdInteractive,
      AuthMethod.azureAdIntegrated,
      AuthMethod.azureAdServicePrincipal,
      AuthMethod.azureAdManagedIdentity,
      AuthMethod.azureAdDefault,
    ],
    'postgres' => const [AuthMethod.password, AuthMethod.kerberos, AuthMethod.azureAdDefault, AuthMethod.awsIam],
    'mysql' => const [AuthMethod.password, AuthMethod.kerberos, AuthMethod.azureAdDefault, AuthMethod.awsIam],
    'oracle' => const [AuthMethod.password, AuthMethod.kerberos],
    'db2' => const [AuthMethod.password, AuthMethod.kerberos],
    'snowflake' => const [AuthMethod.password, AuthMethod.ssoBrowser, AuthMethod.okta, AuthMethod.oauthToken, AuthMethod.keyPair],
    'redshift' => const [AuthMethod.password, AuthMethod.awsIam, AuthMethod.ssoBrowser, AuthMethod.okta, AuthMethod.azureAdInteractive],
    'databricks' => const [AuthMethod.oauthToken, AuthMethod.ssoBrowser, AuthMethod.azureAdServicePrincipal],
    'bigquery' => const [AuthMethod.keyPair, AuthMethod.oauthToken, AuthMethod.ssoBrowser],
    'athena' => const [AuthMethod.awsIam, AuthMethod.ssoBrowser, AuthMethod.okta],
    'sqlite' || 'access' || 'duckdb' => const [AuthMethod.none, AuthMethod.password],
    _ => const [AuthMethod.password, AuthMethod.kerberos, AuthMethod.oauthToken, AuthMethod.none],
  };
}

/// Parameters asked for the given method / driver.
List<AuthParam> authParams(ConnectionConfig c, AuthMethod m) {
  final t = c.mode == ConnectionMode.native ? c.nativeDriver : c.template.id;
  switch (m) {
    case AuthMethod.password:
    case AuthMethod.none:
    case AuthMethod.azureAdIntegrated:
      return const [];
    case AuthMethod.kerberos:
      return [
        if (t == 'postgres' || t == 'mongodb')
          AuthParam('krbServiceName', 'Nome servizio Kerberos', hint: t == 'mongodb' ? 'mongodb' : 'postgres'),
        if (t == 'sqlserver') const AuthParam('serverSpn', 'SPN del server', hint: 'MSSQLSvc/host:1433 (facoltativo)'),
        const AuthParam(
          'krbPrincipal',
          'Principal',
          hint: 'utente@REALM (facoltativo)',
          help: 'Serve un ticket valido: esegui kinit prima di connetterti.',
        ),
      ];
    case AuthMethod.azureAdPassword:
    case AuthMethod.azureAdInteractive:
      return [if (t == 'redshift') ...const [AuthParam('tenantId', 'Tenant ID'), AuthParam('clientId', 'Client ID')]];
    case AuthMethod.azureAdServicePrincipal:
      return const [
        AuthParam('tenantId', 'Tenant ID'),
        AuthParam('clientId', 'Client ID (app)'),
        AuthParam('clientSecret', 'Client secret', secret: true),
      ];
    case AuthMethod.azureAdManagedIdentity:
      return const [AuthParam('clientId', 'Client ID identità', hint: 'Solo per identità assegnate dall\'utente')];
    case AuthMethod.azureAdDefault:
      return const [
        AuthParam('tenantId', 'Tenant ID', hint: 'Facoltativo', help: 'Il token viene richiesto ad Azure CLI (`az login`).'),
      ];
    case AuthMethod.gcpDefault:
      return const [];
    case AuthMethod.ssoBrowser:
      return [
        if (t == 'redshift' || t == 'athena')
          const AuthParam('loginUrl', 'URL di login SAML', hint: 'https://idp.azienda.it/app/…/sso/saml'),
        if (t == 'redshift') ...const [
          AuthParam('clusterId', 'Cluster ID'),
          AuthParam('awsRegion', 'Regione AWS', hint: 'eu-west-1'),
        ],
        if (t == 'databricks') const AuthParam('clientId', 'Client ID OAuth', hint: 'Facoltativo'),
      ];
    case AuthMethod.okta:
      return [
        if (t == 'snowflake') const AuthParam('oktaUrl', 'URL Okta', hint: 'https://azienda.okta.com'),
        if (t == 'redshift' || t == 'athena') ...const [
          AuthParam('idpHost', 'Host Okta', hint: 'azienda.okta.com'),
          AuthParam('appId', 'App ID'),
          AuthParam('appName', 'Nome app', hint: 'amazon_aws'),
        ],
        if (t == 'redshift') ...const [
          AuthParam('clusterId', 'Cluster ID'),
          AuthParam('awsRegion', 'Regione AWS', hint: 'eu-west-1'),
        ],
      ];
    case AuthMethod.awsIam:
      return [
        const AuthParam('awsProfile', 'Profilo AWS', hint: 'default', help: 'Letto da ~/.aws/credentials'),
        const AuthParam('awsRegion', 'Regione AWS', hint: 'eu-west-1'),
        const AuthParam('awsAccessKeyId', 'Access key ID', hint: 'Facoltativo, al posto del profilo'),
        const AuthParam('awsSecretAccessKey', 'Secret access key', secret: true),
        if (t == 'redshift') ...const [AuthParam('clusterId', 'Cluster ID'), AuthParam('dbUser', 'Utente DB')],
        if (t == 'athena') const AuthParam('s3Output', 'Output S3', hint: 's3://bucket/athena-results/'),
      ];
    case AuthMethod.oauthToken:
      return const [AuthParam('token', 'Access token', secret: true)];
    case AuthMethod.keyPair:
      return [
        if (t == 'bigquery') ...const [
          AuthParam('keyFile', 'File chiave service account (JSON)', file: true),
          AuthParam('serviceAccount', 'Email service account', hint: 'Facoltativo se presente nel file'),
        ] else ...const [
          AuthParam('privateKeyFile', 'File chiave privata (.p8)', file: true),
          AuthParam('privateKeyPassphrase', 'Passphrase', secret: true),
        ],
      ];
  }
}

/// Connection string attributes for the selected method (driver mode).
/// [token] is a pre-fetched access token (Entra ID / IAM) when needed.
Map<String, String> authAttributes(ConnectionConfig c, {String? token}) {
  final m = c.authMethod;
  final t = c.template.id;
  String p(String k) => c.authParams[k] ?? c.secretParams[k] ?? '';
  final a = <String, String>{};
  switch (t) {
    case 'sqlserver':
      switch (m) {
        case AuthMethod.kerberos:
          a['Trusted_Connection'] = 'yes';
          if (p('serverSpn').isNotEmpty) a['ServerSPN'] = p('serverSpn');
        case AuthMethod.azureAdPassword:
          a['Authentication'] = 'ActiveDirectoryPassword';
        case AuthMethod.azureAdInteractive:
          a['Authentication'] = 'ActiveDirectoryInteractive';
        case AuthMethod.azureAdIntegrated:
          a['Authentication'] = 'ActiveDirectoryIntegrated';
        case AuthMethod.azureAdServicePrincipal:
          a['Authentication'] = 'ActiveDirectoryServicePrincipal';
          a['UID'] = p('clientId');
          a['PWD'] = p('clientSecret');
        case AuthMethod.azureAdManagedIdentity:
          a['Authentication'] = 'ActiveDirectoryMsi';
          if (p('clientId').isNotEmpty) a['UID'] = p('clientId');
        case AuthMethod.azureAdDefault:
          // msodbcsql ≥ 18.? supports ActiveDirectoryDefault; older drivers get
          // the token as access token attribute (handled by the caller).
          a['Authentication'] = 'ActiveDirectoryDefault';
        default:
      }
    case 'postgres':
      if (m == AuthMethod.kerberos) {
        a['pqopt'] = '{krbsrvname=${p('krbServiceName').isEmpty ? 'postgres' : p('krbServiceName')}}';
      }
      if ((m == AuthMethod.azureAdDefault || m == AuthMethod.awsIam) && token != null) {
        a['PWD'] = token;
        a['SSLmode'] = 'require';
      }
    case 'mysql':
      if (m == AuthMethod.kerberos) a['DEFAULT_AUTH'] = 'authentication_kerberos_client';
      if ((m == AuthMethod.azureAdDefault || m == AuthMethod.awsIam) && token != null) {
        a['PASSWORD'] = token;
        a['ENABLE_CLEARTEXT_PLUGIN'] = '1';
        a['SSLMODE'] = 'REQUIRED';
      }
    case 'oracle':
      if (m == AuthMethod.kerberos) a['UID'] = '/';
    case 'db2':
      if (m == AuthMethod.kerberos) a['Authentication'] = 'KERBEROS';
    case 'snowflake':
      switch (m) {
        case AuthMethod.ssoBrowser:
          a['authenticator'] = 'externalbrowser';
        case AuthMethod.okta:
          a['authenticator'] = p('oktaUrl');
        case AuthMethod.oauthToken:
          a['authenticator'] = 'oauth';
          a['token'] = p('token');
        case AuthMethod.keyPair:
          a['authenticator'] = 'SNOWFLAKE_JWT';
          a['priv_key_file'] = p('privateKeyFile');
          if (p('privateKeyPassphrase').isNotEmpty) a['priv_key_file_pwd'] = p('privateKeyPassphrase');
        default:
      }
    case 'redshift':
      switch (m) {
        case AuthMethod.awsIam:
          a['IAM'] = '1';
          if (p('awsProfile').isNotEmpty) a['Profile'] = p('awsProfile');
          if (p('awsAccessKeyId').isNotEmpty) {
            a['AccessKeyID'] = p('awsAccessKeyId');
            a['SecretAccessKey'] = p('awsSecretAccessKey');
          }
          if (p('clusterId').isNotEmpty) a['ClusterID'] = p('clusterId');
          if (p('awsRegion').isNotEmpty) a['Region'] = p('awsRegion');
          if (p('dbUser').isNotEmpty) a['DbUser'] = p('dbUser');
        case AuthMethod.ssoBrowser:
          a['IAM'] = '1';
          a['plugin_name'] = 'BrowserSAML';
          a['login_url'] = p('loginUrl');
          if (p('clusterId').isNotEmpty) a['ClusterID'] = p('clusterId');
          if (p('awsRegion').isNotEmpty) a['Region'] = p('awsRegion');
        case AuthMethod.okta:
          a['IAM'] = '1';
          a['plugin_name'] = 'Okta';
          a['idp_host'] = p('idpHost');
          a['app_id'] = p('appId');
          if (p('appName').isNotEmpty) a['app_name'] = p('appName');
          if (p('clusterId').isNotEmpty) a['ClusterID'] = p('clusterId');
          if (p('awsRegion').isNotEmpty) a['Region'] = p('awsRegion');
        case AuthMethod.azureAdInteractive:
          a['IAM'] = '1';
          a['plugin_name'] = 'BrowserAzureAD';
          a['idp_tenant'] = p('tenantId');
          a['client_id'] = p('clientId');
        default:
      }
    case 'databricks':
      switch (m) {
        case AuthMethod.oauthToken:
          a['AuthMech'] = '3';
          a['UID'] = 'token';
          a['PWD'] = p('token');
        case AuthMethod.ssoBrowser:
          a['AuthMech'] = '11';
          a['Auth_Flow'] = '2';
          if (p('clientId').isNotEmpty) a['Auth_Client_ID'] = p('clientId');
        case AuthMethod.azureAdServicePrincipal:
          a['AuthMech'] = '11';
          a['Auth_Flow'] = '1';
          a['Auth_Client_ID'] = p('clientId');
          a['Auth_Client_Secret'] = p('clientSecret');
        default:
      }
    case 'bigquery':
      switch (m) {
        case AuthMethod.keyPair:
          a['OAuthMechanism'] = '0';
          a['KeyFilePath'] = p('keyFile');
          if (p('serviceAccount').isNotEmpty) a['Email'] = p('serviceAccount');
        case AuthMethod.oauthToken:
          a['OAuthMechanism'] = '2';
          a['AccessToken'] = p('token');
        case AuthMethod.ssoBrowser:
          a['OAuthMechanism'] = '1';
        default:
      }
    case 'athena':
      switch (m) {
        case AuthMethod.awsIam:
          if (p('awsAccessKeyId').isNotEmpty) {
            a['AuthenticationType'] = 'IAM Credentials';
            a['UID'] = p('awsAccessKeyId');
            a['PWD'] = p('awsSecretAccessKey');
          } else {
            a['AuthenticationType'] = 'IAM Profile';
            a['AWSProfile'] = p('awsProfile').isEmpty ? 'default' : p('awsProfile');
          }
          if (p('awsRegion').isNotEmpty) a['AwsRegion'] = p('awsRegion');
          if (p('s3Output').isNotEmpty) a['S3OutputLocation'] = p('s3Output');
        case AuthMethod.ssoBrowser:
          a['AuthenticationType'] = 'BrowserSAML';
          a['login_url'] = p('loginUrl');
        case AuthMethod.okta:
          a['AuthenticationType'] = 'Okta';
          a['idp_host'] = p('idpHost');
          a['App_ID'] = p('appId');
        default:
      }
    default:
      if (m == AuthMethod.kerberos) a['Trusted_Connection'] = 'yes';
      if (m == AuthMethod.oauthToken) a['Token'] = p('token');
  }
  return a;
}

/// The method needs an access token fetched by DbCraft before connecting
/// (the driver cannot obtain it by itself).
bool needsExternalToken(ConnectionConfig c) {
  if (c.mode == ConnectionMode.native) return false;
  final t = c.template.id;
  return (t == 'postgres' || t == 'mysql') && (c.authMethod == AuthMethod.azureAdDefault || c.authMethod == AuthMethod.awsIam);
}
