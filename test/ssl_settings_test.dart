import 'package:dbcraft/model/auth_methods.dart';
import 'package:dbcraft/model/connection_config.dart';
import 'package:dbcraft/model/ssl_settings.dart';
import 'package:flutter_test/flutter_test.dart';

ConnectionConfig _cfg(String driver, {SslMode mode = SslMode.driverDefault, String ca = '', String cert = '', String key = ''}) =>
    ConnectionConfig(
      id: '1',
      name: 'x',
      driver: driver,
      host: 'h',
      sslMode: mode,
      sslCa: ca,
      sslCert: cert,
      sslKey: key,
    );

void main() {
  test('driver default adds nothing', () {
    expect(_cfg('MariaDB ODBC Driver').buildConnectionString(), 'DRIVER={MariaDB ODBC Driver};SERVER=h');
    expect(_cfg('PostgreSQL Unicode').buildConnectionString(), 'DRIVER={PostgreSQL Unicode};SERVER=h');
  });

  test('MariaDB Connector/ODBC: FORCETLS, SSLVERIFY and files (Azure MySQL)', () {
    final c = _cfg('MariaDB ODBC Driver', mode: SslMode.verifyFull, ca: '/certs/DigiCertGlobalRootG2.crt.pem');
    expect(
      c.buildConnectionString(),
      'DRIVER={MariaDB ODBC Driver};SERVER=h;FORCETLS=1;SSLVERIFY=1;SSLCA=/certs/DigiCertGlobalRootG2.crt.pem',
    );
    // No "verify CA only": the stronger check is used.
    expect(effectiveSslMode(_cfg('MariaDB ODBC Driver', mode: SslMode.verifyCa)), SslMode.verifyFull);
    expect(effectiveSslMode(_cfg('MariaDB ODBC Driver', mode: SslMode.disable)), SslMode.driverDefault);
    expect(
      sslAttributes(_cfg('/opt/x/libmaodbc.dylib', mode: SslMode.require, cert: '/c.pem', key: '/k.pem')),
      {'FORCETLS': '1', 'SSLCERT': '/c.pem', 'SSLKEY': '/k.pem'},
    );
  });

  test('MySQL Connector/ODBC: SSLMODE', () {
    final c = _cfg('MySQL ODBC 9.1 Unicode Driver', mode: SslMode.verifyCa, ca: '/my ca.pem');
    expect(c.buildConnectionString(), 'DRIVER={MySQL ODBC 9.1 Unicode Driver};SERVER=h;SSLMODE=VERIFY_CA;SSLCA=/my ca.pem');
    expect(sslAttributes(_cfg('MySQL ODBC 9.1 Unicode Driver', mode: SslMode.disable, ca: '/a.pem')), {'SSLMODE': 'DISABLED'});
  });

  test('psqlODBC: SSLmode and libpq files in pqopt', () {
    final c = _cfg('PostgreSQL Unicode', mode: SslMode.verifyFull, ca: '/ca dir/root.pem', key: "/k'ey");
    expect(sslAttributes(c), {'SSLmode': 'verify-full', 'pqopt': r"sslrootcert='/ca dir/root.pem' sslkey='/k\'ey'"});
    // Kerberos options are joined with the SSL ones.
    c
      ..authMethod = AuthMethod.kerberos
      ..sslKey = '';
    expect(c.buildConnectionString(), contains('pqopt=krbsrvname=postgres sslrootcert=\'/ca dir/root.pem\''));
  });

  test('SQL Server: Encrypt / TrustServerCertificate replace the template default', () {
    expect(
      _cfg('ODBC Driver 18 for SQL Server', mode: SslMode.verifyFull).buildConnectionString(),
      'DRIVER={ODBC Driver 18 for SQL Server};SERVER=h;Encrypt=yes;TrustServerCertificate=no;MARS_Connection=yes',
    );
    expect(sslSupportsFiles(_cfg('ODBC Driver 18 for SQL Server')), isFalse);
  });

  test('driver parameters win over the SSL section', () {
    final c = _cfg('MySQL ODBC 9.1 Unicode Driver', mode: SslMode.require)..extraParams = {'sslmode': 'VERIFY_IDENTITY'};
    expect(c.buildConnectionString(), 'DRIVER={MySQL ODBC 9.1 Unicode Driver};SERVER=h;sslmode=VERIFY_IDENTITY');
  });

  test('not offered outside driver mode or for unknown drivers', () {
    expect(supportedSslModes(_cfg('Oracle 23 ODBC driver')), isEmpty);
    expect(supportedSslModes(_cfg('PostgreSQL Unicode')..mode = ConnectionMode.dsn), isEmpty);
  });

  test('JSON round trip', () {
    final c = _cfg('PostgreSQL Unicode', mode: SslMode.verifyCa, ca: '/a', cert: '/b', key: '/c');
    final r = ConnectionConfig.fromJson(c.toJson());
    expect([r.sslMode, r.sslCa, r.sslCert, r.sslKey], [SslMode.verifyCa, '/a', '/b', '/c']);
    expect(_cfg('x').toJson().keys.where((k) => k.startsWith('ssl')), isEmpty);
  });
}
