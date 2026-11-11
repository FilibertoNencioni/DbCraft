// SSL/TLS settings of ODBC driver connections, translated into the
// connection string keywords of each driver:
//
//  * MySQL Connector/ODBC: SSLMODE (DISABLED … VERIFY_IDENTITY), SSLCA,
//    SSLCERT, SSLKEY.
//  * MariaDB Connector/ODBC (also used for MySQL): FORCETLS, SSLVERIFY,
//    SSLCA, SSLCERT, SSLKEY. It has no "disabled" / "verify CA only" mode:
//    the certificate check always includes the host name.
//  * psqlODBC: SSLmode (disable … verify-full); the files are libpq options
//    passed through `pqopt` (sslrootcert, sslcert, sslkey).
//  * Microsoft ODBC Driver for SQL Server: Encrypt, TrustServerCertificate
//    (the CA comes from the system trust store).
//
// Other drivers take their SSL keywords from "Parametri del driver".

import 'connection_config.dart';

enum SslMode {
  driverDefault('Predefinita del driver', 'Il driver decide se e come cifrare la connessione'),
  disable('Disattivata', 'Connessione non cifrata'),
  prefer('Se disponibile', 'Cifrata se il server lo consente, senza verificare il certificato'),
  require('Obbligatoria', 'Sempre cifrata, senza verificare il certificato del server'),
  verifyCa('Verifica CA', 'Cifrata; il certificato del server deve essere firmato dalla CA'),
  verifyFull('Verifica CA e host', 'Cifrata; il certificato deve essere firmato dalla CA e intestato all\'host');

  const SslMode(this.label, this.description);
  final String label;
  final String description;

  /// The server certificate is checked: a CA file usually goes with it.
  bool get verifies => this == verifyCa || this == verifyFull;
}

/// The driver is MariaDB Connector/ODBC (registered name or library path).
bool _isMariaDb(ConnectionConfig c) => RegExp('maria|maodbc', caseSensitive: false).hasMatch(c.driver);

/// SSL modes the driver of [c] can express; empty when DbCraft has no
/// knowledge of its SSL keywords (the section is hidden).
List<SslMode> supportedSslModes(ConnectionConfig c) {
  if (c.mode != ConnectionMode.driver) return const [];
  return switch (c.template.id) {
    'mysql' when _isMariaDb(c) => const [SslMode.driverDefault, SslMode.require, SslMode.verifyFull],
    'mysql' || 'postgres' => SslMode.values,
    'sqlserver' => const [SslMode.driverDefault, SslMode.disable, SslMode.require, SslMode.verifyFull],
    _ => const [],
  };
}

/// The mode actually used with the driver of [c]: one it does not support
/// falls back to the closest one that is not weaker (verify CA → verify CA
/// and host), or to the driver default.
SslMode effectiveSslMode(ConnectionConfig c) {
  final modes = supportedSslModes(c);
  if (modes.contains(c.sslMode)) return c.sslMode;
  if (c.sslMode.verifies && modes.contains(SslMode.verifyFull)) return SslMode.verifyFull;
  return SslMode.driverDefault;
}

/// The driver accepts CA / client certificate / key files.
bool sslSupportsFiles(ConnectionConfig c) => const {'mysql', 'postgres'}.contains(c.template.id);

/// Connection string attributes for the SSL settings of [c] (driver mode).
Map<String, String> sslAttributes(ConnectionConfig c) {
  final modes = supportedSslModes(c);
  if (modes.isEmpty) return const {};
  final mode = effectiveSslMode(c);
  final files = sslSupportsFiles(c) && mode != SslMode.disable;
  final ca = files ? c.sslCa.trim() : '', cert = files ? c.sslCert.trim() : '', key = files ? c.sslKey.trim() : '';
  final a = <String, String>{};
  switch (c.template.id) {
    case 'mysql' when _isMariaDb(c):
      if (mode == SslMode.require || mode == SslMode.verifyFull) a['FORCETLS'] = '1';
      if (mode == SslMode.verifyFull) a['SSLVERIFY'] = '1';
      if (ca.isNotEmpty) a['SSLCA'] = ca;
      if (cert.isNotEmpty) a['SSLCERT'] = cert;
      if (key.isNotEmpty) a['SSLKEY'] = key;
    case 'mysql':
      final m = switch (mode) {
        SslMode.driverDefault => null,
        SslMode.disable => 'DISABLED',
        SslMode.prefer => 'PREFERRED',
        SslMode.require => 'REQUIRED',
        SslMode.verifyCa => 'VERIFY_CA',
        SslMode.verifyFull => 'VERIFY_IDENTITY',
      };
      if (m != null) a['SSLMODE'] = m;
      if (ca.isNotEmpty) a['SSLCA'] = ca;
      if (cert.isNotEmpty) a['SSLCERT'] = cert;
      if (key.isNotEmpty) a['SSLKEY'] = key;
    case 'postgres':
      final m = switch (mode) {
        SslMode.driverDefault => null,
        SslMode.disable => 'disable',
        SslMode.prefer => 'prefer',
        SslMode.require => 'require',
        SslMode.verifyCa => 'verify-ca',
        SslMode.verifyFull => 'verify-full',
      };
      if (m != null) a['SSLmode'] = m;
      final pq = [
        if (ca.isNotEmpty) 'sslrootcert=${libpqQuote(ca)}',
        if (cert.isNotEmpty) 'sslcert=${libpqQuote(cert)}',
        if (key.isNotEmpty) 'sslkey=${libpqQuote(key)}',
      ];
      if (pq.isNotEmpty) a['pqopt'] = pq.join(' ');
    case 'sqlserver':
      switch (mode) {
        case SslMode.disable:
          a['Encrypt'] = 'no';
        case SslMode.require:
          a['Encrypt'] = 'yes';
          a['TrustServerCertificate'] = 'yes';
        case SslMode.verifyFull:
          a['Encrypt'] = 'yes';
          a['TrustServerCertificate'] = 'no';
        default:
      }
  }
  return a;
}

/// Quotes a value of a libpq conninfo string (`key='va lue'`) when needed.
String libpqQuote(String v) {
  if (v.isNotEmpty && !RegExp(r"[\s'\\]").hasMatch(v)) return v;
  return "'${v.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
}
