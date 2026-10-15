// SCRAM-SHA-1 / SCRAM-SHA-256 client (RFC 5802, RFC 7677) as used by
// MongoDB, with a minimal SASLprep (RFC 4013).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../common/native_exception.dart';

/// Minimal SASLprep: maps non-ASCII spaces to U+0020, removes the characters
/// "commonly mapped to nothing" and rejects control characters. (Unicode
/// NFKC normalization is not applied; ASCII passwords are unaffected.)
String saslPrep(String s) {
  if (s.codeUnits.every((c) => c >= 0x20 && c < 0x7f)) return s;
  const spaces = {0x00A0, 0x1680, 0x202F, 0x205F, 0x3000};
  const nothing = {0x00AD, 0x034F, 0x1806, 0x180B, 0x180C, 0x180D, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF};
  final sb = StringBuffer();
  for (final r in s.runes) {
    if (nothing.contains(r) || (r >= 0xFE00 && r <= 0xFE0F)) continue;
    if (spaces.contains(r) || (r >= 0x2000 && r <= 0x200A)) {
      sb.write(' ');
      continue;
    }
    if (r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0)) {
      throw NativeDbException('La password contiene caratteri di controllo non ammessi (SASLprep)');
    }
    sb.writeCharCode(r);
  }
  return sb.toString();
}

/// Salted passwords are expensive (PBKDF2): cached per process.
final Map<String, List<int>> _saltedCache = {};

List<int> pbkdf2(Hash hash, List<int> password, List<int> salt, int iterations) {
  final mac = Hmac(hash, password);
  var u = mac.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = mac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

class ScramClient {
  ScramClient({required this.sha256Mode, required this.username, required String password, String? clientNonce})
    : _password = sha256Mode ? saslPrep(password) : md5.convert(utf8.encode('$username:mongo:$password')).toString(),
      nonce = clientNonce ?? base64.encode(List.generate(24, (_) => Random.secure().nextInt(256)));

  final bool sha256Mode;
  final String username;
  final String _password;
  final String nonce;

  String? _clientFirstBare;
  List<int>? _serverSignature;

  Hash get _hash => sha256Mode ? sha256 : sha1;

  String get mechanism => sha256Mode ? 'SCRAM-SHA-256' : 'SCRAM-SHA-1';

  static String _escapeUser(String u) => u.replaceAll('=', '=3D').replaceAll(',', '=2C');

  String clientFirst() {
    _clientFirstBare = 'n=${_escapeUser(username)},r=$nonce';
    return 'n,,$_clientFirstBare';
  }

  static Map<String, String> _attrs(String msg) {
    final m = <String, String>{};
    for (final part in msg.split(',')) {
      final i = part.indexOf('=');
      if (i > 0) m[part.substring(0, i)] = part.substring(i + 1);
    }
    return m;
  }

  /// Computes the client-final-message from the server-first-message.
  String clientFinal(String serverFirst) {
    final a = _attrs(serverFirst);
    if (a.containsKey('e')) throw NativeDbException('Autenticazione SCRAM rifiutata: ${a['e']}');
    final r = a['r'] ?? '';
    final s = a['s'] ?? '';
    final i = int.tryParse(a['i'] ?? '') ?? 0;
    if (!r.startsWith(nonce) || s.isEmpty || i <= 0) {
      throw NativeDbException('Risposta SCRAM del server non valida');
    }
    if (i < 4096) throw NativeDbException('Numero di iterazioni SCRAM troppo basso ($i)');
    final salt = base64.decode(s);
    final key = '$mechanism\u0000$_password\u0000$s\u0000$i';
    final salted = _saltedCache[key] ??= pbkdf2(_hash, utf8.encode(_password), salt, i);
    final clientKey = Hmac(_hash, salted).convert(utf8.encode('Client Key')).bytes;
    final storedKey = _hash.convert(clientKey).bytes;
    final withoutProof = 'c=biws,r=$r';
    final authMessage = '$_clientFirstBare,$serverFirst,$withoutProof';
    final clientSig = Hmac(_hash, storedKey).convert(utf8.encode(authMessage)).bytes;
    final proof = [for (var k = 0; k < clientKey.length; k++) clientKey[k] ^ clientSig[k]];
    final serverKey = Hmac(_hash, salted).convert(utf8.encode('Server Key')).bytes;
    _serverSignature = Hmac(_hash, serverKey).convert(utf8.encode(authMessage)).bytes;
    return '$withoutProof,p=${base64.encode(proof)}';
  }

  /// Checks the server-final-message (`v=…`).
  void verifyServerFinal(String serverFinal) {
    final a = _attrs(serverFinal);
    if (a.containsKey('e')) throw NativeDbException('Autenticazione SCRAM rifiutata: ${a['e']}');
    final v = a['v'];
    if (v == null || _serverSignature == null || v != base64.encode(_serverSignature!)) {
      throw NativeDbException('Firma SCRAM del server non valida');
    }
  }
}
