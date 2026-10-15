// A single MongoDB server connection: TCP/TLS, OP_MSG request/response,
// handshake (hello / isMaster), replica set primary discovery and
// authentication (SCRAM-SHA-256, SCRAM-SHA-1, PLAIN, MONGODB-X509,
// MONGODB-AWS, MONGODB-OIDC).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../common/aws_sigv4.dart';
import '../common/dns.dart';
import '../common/native_exception.dart';
import '../common/net.dart';
import 'bson.dart';
import 'mongo_uri.dart';
import 'scram.dart';
import 'wire.dart';

const mongoDriverVersion = '1.0.0';

/// Resolved connection settings.
class MongoSettings {
  MongoSettings({
    required this.seeds,
    required this.net,
    this.srvHost,
    this.user = '',
    this.password = '',
    this.authSource = '',
    this.authMechanism = '',
    this.mechanismProperties = const {},
    this.replicaSet = '',
    this.readPreference = 'primary',
    this.directConnection = false,
    this.appName = 'DbCraft',
    this.database = 'test',
    this.authMethod = 'password',
    this.awsProfile = '',
    this.awsAccessKeyId = '',
    this.awsSecretAccessKey = '',
    this.awsSessionToken = '',
    this.oidcToken = '',
  });

  List<MongoHost> seeds;
  final String? srvHost;
  final NetOptions net;
  final String user;
  final String password;
  final String authSource;
  final String authMechanism;
  final Map<String, String> mechanismProperties;
  final String replicaSet;
  final String readPreference;
  final bool directConnection;
  final String appName;
  final String database;

  /// AuthMethod name chosen in the connection dialog.
  final String authMethod;
  final String awsProfile;
  final String awsAccessKeyId;
  final String awsSecretAccessKey;
  final String awsSessionToken;
  final String oidcToken;

  bool get allowSecondary => readPreference != 'primary';
}

/// Error returned by a command (`ok: 0`, write errors).
class MongoCommandException extends NativeDbException {
  MongoCommandException(super.message, {super.code, this.numericCode}) : super(source: 'MongoDB');
  final int? numericCode;
}

class MongoConnection {
  MongoConnection._(this.address, this._socket) : _reader = ByteReader(_socket);

  final MongoHost address;
  final Socket _socket;
  final ByteReader _reader;
  int _requestId = 0;
  bool _closed = false;
  Map<String, Object?> hello = const {};

  /// Connected to a secondary: commands carry $readPreference.
  bool secondary = false;
  String readPreference = 'primary';

  bool get isClosed => _closed || _reader.isDone;
  int get maxWireVersion => bsonInt(hello['maxWireVersion']) ?? 0;

  // -------------------------------------------------------------------------
  // Connection establishment
  // -------------------------------------------------------------------------

  /// Resolves mongodb+srv seeds and options (SRV and TXT records).
  static Future<(List<MongoHost>, Map<String, String>)> resolveSrvSeeds(String host) async {
    final records = await resolveSrv('_mongodb._tcp.$host');
    if (records.isEmpty) throw NativeDbException('Nessun record SRV per _mongodb._tcp.$host');
    final parent = host.split('.').skip(1).join('.').toLowerCase();
    final seeds = <MongoHost>[];
    for (final r in records) {
      final target = r.target.endsWith('.') ? r.target.substring(0, r.target.length - 1) : r.target;
      if (parent.isNotEmpty && !target.toLowerCase().endsWith('.$parent')) {
        throw NativeDbException('Record SRV "$target" non appartiene al dominio $parent');
      }
      seeds.add(MongoHost(target, r.port));
    }
    final opts = <String, String>{};
    final txt = await resolveTxt(host);
    if (txt.length > 1) throw NativeDbException('Più record TXT per $host');
    if (txt.isNotEmpty) {
      for (final part in txt.first.split('&')) {
        final i = part.indexOf('=');
        if (i <= 0) continue;
        final k = part.substring(0, i).toLowerCase();
        if (k != 'authsource' && k != 'replicaset' && k != 'loadbalanced') {
          throw NativeDbException('Opzione TXT non ammessa: $k');
        }
        opts[k] = Uri.decodeQueryComponent(part.substring(i + 1));
      }
    }
    return (seeds, opts);
  }

  static Future<MongoConnection> _open(MongoHost h, NetOptions net) async {
    final s = await connectSocket(h.host, h.port, net);
    return MongoConnection._(h, s);
  }

  /// Connects to the right member of the deployment and authenticates.
  static Future<MongoConnection> connect(MongoSettings st) async {
    final errors = <String>[];
    final tried = <MongoHost>{};
    final queue = [...st.seeds];
    MongoConnection? fallback;
    while (queue.isNotEmpty) {
      final h = queue.removeAt(0);
      if (!tried.add(h)) continue;
      MongoConnection c;
      try {
        c = await _open(h, st.net);
        await c._handshake(st);
      } catch (e) {
        errors.add('$h: ${e is NativeDbException ? e.message : e}');
        continue;
      }
      final hello = c.hello;
      final setName = hello['setName'] as String?;
      if (st.replicaSet.isNotEmpty && setName != null && setName != st.replicaSet) {
        errors.add('$h: replica set "$setName" diverso da "${st.replicaSet}"');
        await c.close();
        continue;
      }
      final primary = hello['isWritablePrimary'] == true || hello['ismaster'] == true;
      final mongos = hello['msg'] == 'isdbgrid';
      if (st.directConnection || primary || mongos || setName == null) {
        return c._finish(st, secondary: !primary && !mongos && setName != null);
      }
      if (hello['arbiterOnly'] == true || hello['hidden'] == true) {
        await c.close();
      } else if (st.allowSecondary && hello['secondary'] == true) {
        if (st.readPreference.startsWith('secondary') || st.readPreference == 'nearest') {
          return c._finish(st, secondary: true);
        }
        // primaryPreferred: keep as fallback while looking for the primary.
        if (fallback == null) {
          fallback = c;
        } else {
          await c.close();
        }
      } else {
        await c.close();
      }
      final p = hello['primary'] as String?;
      if (p != null) queue.insert(0, MongoHost.parse(p));
      for (final x in (hello['hosts'] as List? ?? const [])) {
        queue.add(MongoHost.parse(x.toString()));
      }
    }
    if (fallback != null) return fallback._finish(st, secondary: true);
    throw NativeDbException(
      errors.isEmpty
          ? 'Nessun primary disponibile nel replica set'
          : 'Connessione a MongoDB non riuscita:\n${errors.join('\n')}',
    );
  }

  Future<MongoConnection> _finish(MongoSettings st, {required bool secondary}) async {
    this.secondary = secondary;
    readPreference = secondary && st.readPreference == 'primary' ? 'primaryPreferred' : st.readPreference;
    try {
      await _authenticate(st);
    } catch (_) {
      await close();
      rethrow;
    }
    return this;
  }

  Future<void> _handshake(MongoSettings st) async {
    final mech = st.authMechanism.toUpperCase();
    final cmd = <String, Object?>{
      'hello': 1,
      'helloOk': true,
      'client': {
        'driver': {'name': 'DbCraft', 'version': mongoDriverVersion},
        'os': {'type': Platform.operatingSystem, 'name': Platform.operatingSystemVersion},
        'platform': 'Dart ${Platform.version.split(' ').first}',
        if (st.appName.isNotEmpty) 'application': {'name': st.appName},
      },
      if (st.user.isNotEmpty && (mech.isEmpty || mech == 'DEFAULT') && st.authMethod == 'password')
        'saslSupportedMechs': '${st.authSource.isEmpty ? 'admin' : st.authSource}.${st.user}',
    };
    try {
      hello = await command('admin', cmd, applyReadPreference: false);
    } on MongoCommandException catch (e) {
      if (e.numericCode != 59) rethrow; // CommandNotFound: pre-4.4.2 server
      cmd.remove('hello');
      cmd.remove('helloOk');
      hello = await command('admin', {'isMaster': 1, ...cmd}, applyReadPreference: false);
    }
    if (maxWireVersion < 6) {
      throw NativeDbException('Versione di MongoDB non supportata: serve la 3.6 o successiva');
    }
  }

  // -------------------------------------------------------------------------
  // Authentication
  // -------------------------------------------------------------------------

  Future<void> _authenticate(MongoSettings st) async {
    var mech = st.authMechanism.toUpperCase();
    switch (st.authMethod) {
      case 'none':
        if (mech != 'MONGODB-X509') return;
      case 'kerberos':
        throw NativeDbException('Autenticazione Kerberos (GSSAPI) non supportata dal driver integrato MongoDB');
      case 'awsIam':
        mech = 'MONGODB-AWS';
      case 'oauthToken':
        mech = 'MONGODB-OIDC';
    }
    if (mech.isEmpty || mech == 'DEFAULT') {
      if (st.user.isEmpty) return;
      final supported = (hello['saslSupportedMechs'] as List?)?.map((e) => e.toString()).toList();
      mech = supported == null || supported.contains('SCRAM-SHA-256') ? 'SCRAM-SHA-256' : 'SCRAM-SHA-1';
      if (supported != null && supported.isNotEmpty && !supported.contains(mech)) mech = 'SCRAM-SHA-1';
    }
    final source = st.authSource.isNotEmpty
        ? st.authSource
        : (const {'PLAIN', 'MONGODB-X509', 'MONGODB-AWS', 'MONGODB-OIDC', 'GSSAPI'}.contains(mech)
              ? r'$external'
              : 'admin');
    switch (mech) {
      case 'SCRAM-SHA-256':
      case 'SCRAM-SHA-1':
        if (st.user.isEmpty) throw NativeDbException('Utente obbligatorio per $mech');
        await _scram(
          source,
          ScramClient(sha256Mode: mech == 'SCRAM-SHA-256', username: st.user, password: st.password),
        );
      case 'PLAIN':
        final payload = utf8.encode('\u0000${st.user}\u0000${st.password}');
        await command(source, {
          'saslStart': 1,
          'mechanism': 'PLAIN',
          'payload': Uint8List.fromList(payload),
          'autoAuthorize': 1,
        }, applyReadPreference: false);
      case 'MONGODB-X509':
        if (!st.net.tls) throw NativeDbException('MONGODB-X509 richiede TLS e un certificato client');
        await command(r'$external', {
          'authenticate': 1,
          'mechanism': 'MONGODB-X509',
          if (st.user.isNotEmpty) 'user': st.user,
        }, applyReadPreference: false);
      case 'MONGODB-AWS':
        await _aws(st);
      case 'MONGODB-OIDC':
        final token = st.oidcToken.isNotEmpty ? st.oidcToken : st.password;
        if (token.isEmpty) throw NativeDbException('Access token OIDC mancante');
        await command(r'$external', {
          'saslStart': 1,
          'mechanism': 'MONGODB-OIDC',
          'payload': encodeBson({'jwt': token}),
        }, applyReadPreference: false);
      case 'GSSAPI':
        throw NativeDbException('Autenticazione Kerberos (GSSAPI) non supportata dal driver integrato MongoDB');
      default:
        throw NativeDbException('Meccanismo di autenticazione non supportato: $mech');
    }
  }

  static String _payloadString(Object? p) => switch (p) {
    Uint8List() => utf8.decode(p),
    BsonBinary() => utf8.decode(p.data),
    String() => p,
    _ => '',
  };

  Future<void> _scram(String db, ScramClient sc) async {
    try {
      var r = await command(db, {
        'saslStart': 1,
        'mechanism': sc.mechanism,
        'payload': Uint8List.fromList(utf8.encode(sc.clientFirst())),
        'autoAuthorize': 1,
        'options': {'skipEmptyExchange': true},
      }, applyReadPreference: false);
      final conv = r['conversationId'];
      final fin = sc.clientFinal(_payloadString(r['payload']));
      r = await command(db, {
        'saslContinue': 1,
        'conversationId': conv,
        'payload': Uint8List.fromList(utf8.encode(fin)),
      }, applyReadPreference: false);
      sc.verifyServerFinal(_payloadString(r['payload']));
      var guard = 0;
      while (r['done'] != true && guard++ < 3) {
        r = await command(db, {
          'saslContinue': 1,
          'conversationId': conv,
          'payload': Uint8List(0),
        }, applyReadPreference: false);
      }
    } on MongoCommandException catch (e) {
      if (e.numericCode == 18) {
        throw NativeDbException(
          'Autenticazione fallita per l\'utente "${sc.username}" (database di autenticazione: $db)',
        );
      }
      rethrow;
    }
  }

  Future<void> _aws(MongoSettings st) async {
    final creds = await AwsCredentials.resolve(
      accessKeyId: st.awsAccessKeyId.isNotEmpty ? st.awsAccessKeyId : st.user,
      secretAccessKey: st.awsSecretAccessKey.isNotEmpty ? st.awsSecretAccessKey : st.password,
      sessionToken: st.awsSessionToken.isNotEmpty
          ? st.awsSessionToken
          : (st.mechanismProperties['AWS_SESSION_TOKEN'] ?? ''),
      profile: st.awsProfile,
    );
    final rnd = Random.secure();
    final nonce = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    var r = await command(r'$external', {
      'saslStart': 1,
      'mechanism': 'MONGODB-AWS',
      'payload': encodeBson({'r': nonce, 'p': 110}),
    }, applyReadPreference: false);
    final payload = r['payload'];
    final server = decodeBson(payload is BsonBinary ? payload.data : payload as Uint8List);
    final s = server['s'];
    final sBytes = s is BsonBinary ? s.data : s as Uint8List;
    final host = server['h'].toString();
    if (sBytes.length != 64 || !_prefix(sBytes, nonce)) {
      throw NativeDbException('MONGODB-AWS: nonce del server non valido');
    }
    if (host.isEmpty || host.contains('..') || host.length > 255) {
      throw NativeDbException('MONGODB-AWS: host STS non valido');
    }
    final parts = host.split('.');
    final region = host == 'sts.amazonaws.com' || parts.length < 2 ? 'us-east-1' : parts[1];
    const body = 'Action=GetCallerIdentity&Version=2011-06-15';
    final date = amzDate(DateTime.now());
    final headers = {
      'content-length': '${body.length}',
      'content-type': 'application/x-www-form-urlencoded',
      'host': host,
      'x-amz-date': date,
      'x-mongodb-gs2-cb-flag': 'n',
      'x-mongodb-server-nonce': base64.encode(sBytes),
      if (creds.sessionToken != null) 'x-amz-security-token': creds.sessionToken!,
    };
    final auth = sigv4Authorization(
      method: 'POST',
      path: '/',
      headers: headers,
      payload: body,
      region: region,
      service: 'sts',
      credentials: creds,
      amzDateValue: date,
    );
    r = await command(r'$external', {
      'saslContinue': 1,
      'conversationId': r['conversationId'],
      'payload': encodeBson({'a': auth, 'd': date, if (creds.sessionToken != null) 't': creds.sessionToken}),
    }, applyReadPreference: false);
  }

  static bool _prefix(Uint8List a, Uint8List p) {
    for (var i = 0; i < p.length; i++) {
      if (a[i] != p[i]) return false;
    }
    return true;
  }

  // -------------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------------

  /// Runs [cmd] on [db]; throws [MongoCommandException] when `ok` is 0 or
  /// the reply contains write errors.
  Future<Map<String, Object?>> command(String db, Map<String, Object?> cmd, {bool applyReadPreference = true}) async {
    if (isClosed) throw NativeDbException('Connessione MongoDB chiusa');
    final body = <String, Object?>{...cmd, r'$db': db};
    if (applyReadPreference && secondary && readPreference != 'primary') {
      body[r'$readPreference'] = {'mode': readPreference};
    }
    final id = _requestId = (_requestId + 1) & 0x7fffffff;
    _socket.add(encodeOpMsg(id, body));
    while (true) {
      final head = await _reader.read(4);
      final len = readInt32LE(head, 0);
      if (len < 16 || len > 48 * 1024 * 1024) throw NativeDbException('Risposta MongoDB non valida (lunghezza $len)');
      final rest = await _reader.read(len - 4);
      final msg = Uint8List(len)
        ..setRange(0, 4, head)
        ..setRange(4, len, rest);
      final reply = decodeOpMsg(msg);
      if (reply.responseTo != id) continue;
      final doc = reply.body;
      // Document sequences (rare in replies) are merged into the body.
      reply.sequences.forEach((k, v) => doc[k] = v);
      _check(doc);
      return doc;
    }
  }

  static void _check(Map<String, Object?> doc) {
    final ok = doc['ok'];
    final okVal = ok is num ? ok : bsonInt(ok) ?? 0;
    if (okVal != 1) {
      final code = bsonInt(doc['code']);
      throw MongoCommandException(
        doc['errmsg']?.toString() ?? 'Comando fallito',
        code: (doc['codeName'] as String?) ?? (code == null ? null : '$code'),
        numericCode: code,
      );
    }
    final we = doc['writeErrors'];
    if (we is List && we.isNotEmpty) {
      final first = we.first as Map;
      final n = bsonInt(doc['n']) ?? 0;
      final code = bsonInt(first['code']);
      throw MongoCommandException(
        '${first['errmsg']}${n > 0 ? ' ($n documenti scritti prima dell\'errore)' : ''}',
        code: code == null ? null : '$code',
        numericCode: code,
      );
    }
    final wce = doc['writeConcernError'];
    if (wce is Map) {
      throw MongoCommandException('Write concern: ${wce['errmsg']}', code: '${wce['code']}');
    }
  }

  void abort(String reason) {
    if (_closed) return;
    _closed = true;
    _reader.fail(NativeDbException(reason == 'cancel' ? 'Operazione annullata' : 'Connessione interrotta ($reason)'));
    _socket.destroy();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reader.fail(NativeDbException('Connessione MongoDB chiusa'));
    try {
      await _socket.close();
    } catch (_) {}
    _socket.destroy();
  }
}
