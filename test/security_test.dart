import 'dart:convert';
import 'dart:io';

import 'package:dbcraft/model/auth_methods.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/services/vault.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('dbcraft_vault'));
  tearDown(() async => dir.delete(recursive: true));

  group('Vault', () {
    test('local key: secrets survive reopening and are not stored in clear', () async {
      final v = await Vault.open(dir);
      expect(v.isLocked, isFalse);
      await v.set('conn:1:password', 's3greta!');
      final raw = await File('${dir.path}/vault.json').readAsString();
      expect(raw.contains('s3greta'), isFalse);
      final again = await Vault.open(dir);
      expect(again.get('conn:1:password'), 's3greta!');
    });

    test('master password locks, rejects wrong passwords and unlocks', () async {
      final v = await Vault.open(dir);
      await v.set('ai.apiKey', 'sk-test');
      await v.setMasterPassword('correct horse');
      expect(File('${dir.path}/vault.key').existsSync(), isFalse);

      final locked = await Vault.open(dir);
      expect(locked.isLocked, isTrue);
      expect(() => locked.get('ai.apiKey'), throwsA(isA<VaultException>()));
      expect(await locked.unlock('wrong'), isFalse);
      expect(await locked.unlock('correct horse'), isTrue);
      expect(locked.get('ai.apiKey'), 'sk-test');

      await locked.setMasterPassword(null);
      final open = await Vault.open(dir);
      expect(open.isLocked, isFalse);
      expect(open.get('ai.apiKey'), 'sk-test');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('prefix helpers and reset', () async {
      final v = await Vault.open(dir);
      await v.setAll('conn:9:secret:', {'clientSecret': 'x', 'token': 'y', 'empty': ''});
      expect(v.withPrefix('conn:9:secret:'), {'clientSecret': 'x', 'token': 'y'});
      await v.removePrefix('conn:9:');
      expect(v.length, 0);
      await v.set('a', 'b');
      await v.reset();
      expect(v.get('a'), isNull);
    });
  });

  group('Authentication', () {
    ConnectionConfig cfg(String driver, AuthMethod m, [Map<String, String> p = const {}]) => ConnectionConfig(
      id: '1',
      name: 'x',
      driver: driver,
      host: 'srv',
      port: '1433',
      database: 'db',
      user: 'me',
      password: 'pw',
      authMethod: m,
      authParams: Map.of(p),
    );

    test('SQL Server Entra ID interactive omits the password', () {
      final s = cfg('ODBC Driver 18 for SQL Server', AuthMethod.azureAdInteractive).buildConnectionString();
      expect(s, contains('Authentication=ActiveDirectoryInteractive'));
      expect(s, contains('UID=me'));
      expect(s, isNot(contains('PWD=')));
    });

    test('SQL Server Kerberos uses Trusted_Connection and no credentials', () {
      final s = cfg('ODBC Driver 18 for SQL Server', AuthMethod.kerberos).buildConnectionString();
      expect(s, contains('Trusted_Connection=yes'));
      expect(s, isNot(contains('UID=')));
      expect(s, isNot(contains('PWD=')));
    });

    test('Snowflake SSO and Okta authenticators', () {
      expect(cfg('SnowflakeDSIIDriver', AuthMethod.ssoBrowser).buildConnectionString(),
          contains('authenticator=externalbrowser'));
      expect(
        cfg('SnowflakeDSIIDriver', AuthMethod.okta, {'oktaUrl': 'https://acme.okta.com'}).buildConnectionString(),
        contains('authenticator=https://acme.okta.com'),
      );
    });

    test('Redshift IAM profile', () {
      final s = cfg('Amazon Redshift ODBC Driver', AuthMethod.awsIam, {'awsProfile': 'dev', 'clusterId': 'c1'})
          .buildConnectionString();
      expect(s, contains('IAM=1'));
      expect(s, contains('Profile=dev'));
      expect(s, contains('ClusterID=c1'));
    });

    test('PostgreSQL with Entra ID token puts the token as password', () {
      final c = cfg('PostgreSQL Unicode', AuthMethod.azureAdDefault);
      expect(needsExternalToken(c), isTrue);
      final s = c.buildConnectionString(token: 'eyJ0');
      expect(s, contains('PWD=eyJ0'));
    });

    test('secrets are not serialized to disk', () {
      final c = cfg('PostgreSQL Unicode', AuthMethod.oauthToken)..secretParams = {'token': 'abc'};
      final disk = jsonEncode(c.toJson());
      expect(disk.contains('abc'), isFalse);
      expect(disk.contains('"password"'), isFalse);
      final copy = c.copy();
      expect(copy.secretParams['token'], 'abc');
      expect(copy.password, 'pw');
    });
  });
}
