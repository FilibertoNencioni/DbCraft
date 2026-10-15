// Access tokens used as database passwords by ODBC connections whose driver
// cannot obtain them by itself:
//  * Microsoft Entra ID for Azure Database for PostgreSQL / MySQL;
//  * AWS IAM database authentication for RDS / Aurora.
//
// Installed as `databaseTokenProvider` of drivers/session_factory.dart.
import '../../model/auth_methods.dart';
import '../../model/connection_config.dart';
import '../cloud_common.dart';
import 'aws_auth.dart';
import 'azure_auth.dart';

/// Scope of Azure Database for PostgreSQL / MySQL (flexible server).
const azureOssRdbmsScope = 'https://ossrdbms-aad.database.windows.net/.default';

/// Returns the token to use as password, or null when [c] does not need one.
Future<String?> fetchDatabaseToken(ConnectionConfig c) async {
  if (!needsExternalToken(c)) return null;
  String p(String k) => (c.authParams[k] ?? c.secretParams[k] ?? '').trim();
  switch (c.authMethod) {
    case AuthMethod.azureAdDefault:
      final AzureCredential cred = p('clientId').isNotEmpty && p('clientSecret').isNotEmpty && p('tenantId').isNotEmpty
          ? AzureClientSecretCredential(
              tenantId: p('tenantId'),
              clientId: p('clientId'),
              clientSecret: p('clientSecret'),
            )
          : AzureCliCredential(tenantId: p('tenantId').isEmpty ? null : p('tenantId'));
      return (await cred.getToken(azureOssRdbmsScope)).token;
    case AuthMethod.awsIam:
      if (c.user.trim().isEmpty) {
        throw CloudException(
          'Per l\'autenticazione IAM di RDS indica l\'utente del database (creato con il ruolo '
          'rds_iam / AWSAuthenticationPlugin).',
        );
      }
      if (c.host.trim().isEmpty) throw CloudException('Indica l\'endpoint RDS (host).');
      final auth = AwsAuth(
        accessKeyId: p('awsAccessKeyId'),
        secretAccessKey: p('awsSecretAccessKey'),
        profile: p('awsProfile'),
        region: p('awsRegion'),
      );
      final region = p('awsRegion').isNotEmpty
          ? p('awsRegion')
          : regionFromRdsHost(c.host.trim()) ?? await auth.profileRegion();
      if (region == null || region.isEmpty) {
        throw CloudException('Indica la regione AWS dell\'istanza RDS.');
      }
      final port = int.tryParse(c.port.trim()) ?? int.tryParse(c.template.defaultPort) ?? 5432;
      return rdsAuthToken(
        host: c.host.trim(),
        port: port,
        region: region,
        dbUser: c.user.trim(),
        creds: await auth.credentials(),
      );
    default:
      return null;
  }
}
