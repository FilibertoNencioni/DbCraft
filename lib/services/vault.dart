// Encrypted credential store ("secure storage" in DBeaver PRO).
//
// Every secret (connection passwords, client secrets, cloud keys, the AI API
// key) is kept in `vault.json`, encrypted with AES-256-GCM. The key is either:
//  * derived from the master password with PBKDF2-HMAC-SHA256 (the vault is
//    locked at startup until the password is typed), or
//  * a random key stored next to the workspace in `vault.key` (readable only
//    by the user) when no master password is set.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

class VaultException implements Exception {
  VaultException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Vault {
  Vault._(this._file, this._keyFile);

  final File _file;
  final File _keyFile;

  Map<String, Object?> _header = {};
  Uint8List? _key;
  Map<String, String> _secrets = {};

  static const _checkText = 'dbcraft-vault-ok';
  static const defaultIterations = 310000;

  /// True when a master password protects the vault.
  bool get usesMasterPassword => _header['mode'] == 'master';

  bool get isLocked => _key == null;

  static Future<Vault> open(Directory root) async {
    final v = Vault._(File(p.join(root.path, 'vault.json')), File(p.join(root.path, 'vault.key')));
    await v._load();
    return v;
  }

  Future<void> _load() async {
    if (await _file.exists()) {
      try {
        _header = (jsonDecode(await _file.readAsString()) as Map).cast<String, Object?>();
      } catch (_) {
        throw VaultException('Il file vault.json è danneggiato.');
      }
    }
    if (_header.isEmpty) {
      // New vault: local key, empty content.
      _key = _randomBytes(32);
      await _writeKeyFile(_key!);
      _header = {'version': 1, 'mode': 'local'};
      _secrets = {};
      await _persist();
      return;
    }
    if (!usesMasterPassword) {
      if (!await _keyFile.exists()) {
        throw VaultException('Chiave del vault mancante (vault.key): le credenziali salvate non sono leggibili.');
      }
      _key = base64Decode((await _keyFile.readAsString()).trim());
      _decryptAll();
    }
  }

  /// Unlocks a vault protected by a master password. Returns false when the
  /// password is wrong.
  Future<bool> unlock(String password) async {
    if (!usesMasterPassword) return true;
    final salt = base64Decode(_header['salt'] as String);
    final iterations = (_header['iterations'] as num?)?.toInt() ?? defaultIterations;
    final key = await deriveKey(password, salt, iterations);
    try {
      final check = _decrypt(key, (_header['check'] as Map).cast());
      if (utf8.decode(check) != _checkText) return false;
    } catch (_) {
      return false;
    }
    _key = key;
    _decryptAll();
    return true;
  }

  /// Deletes every stored secret and starts a new vault without master
  /// password (used when the master password is lost).
  Future<void> reset() async {
    if (await _file.exists()) await _file.delete();
    if (await _keyFile.exists()) await _keyFile.delete();
    _header = {};
    _key = null;
    _secrets = {};
    await _load();
  }

  /// Forgets the key (the master password must be typed again).
  void lock() {
    if (!usesMasterPassword) return;
    _key = null;
    _secrets = {};
  }

  /// Verifies [password] without changing the state.
  Future<bool> checkPassword(String password) async {
    if (!usesMasterPassword) return true;
    final salt = base64Decode(_header['salt'] as String);
    final iterations = (_header['iterations'] as num?)?.toInt() ?? defaultIterations;
    final key = await deriveKey(password, salt, iterations);
    try {
      return utf8.decode(_decrypt(key, (_header['check'] as Map).cast())) == _checkText;
    } catch (_) {
      return false;
    }
  }

  /// Sets, changes or (with null) removes the master password.
  Future<void> setMasterPassword(String? password) async {
    _requireUnlocked();
    if (password == null || password.isEmpty) {
      _key = _randomBytes(32);
      await _writeKeyFile(_key!);
      _header = {'version': 1, 'mode': 'local'};
    } else {
      final salt = _randomBytes(16);
      _key = await deriveKey(password, salt, defaultIterations);
      _header = {
        'version': 1,
        'mode': 'master',
        'kdf': 'pbkdf2-sha256',
        'iterations': defaultIterations,
        'salt': base64Encode(salt),
        'check': _encrypt(_key!, utf8.encode(_checkText)),
      };
      if (await _keyFile.exists()) await _keyFile.delete();
    }
    await _persist();
  }

  String? get(String key) {
    _requireUnlocked();
    return _secrets[key];
  }

  /// Stores (or with null/empty removes) a secret.
  Future<void> set(String key, String? value) async {
    _requireUnlocked();
    if (value == null || value.isEmpty) {
      if (_secrets.remove(key) == null) return;
    } else {
      if (_secrets[key] == value) return;
      _secrets[key] = value;
    }
    await _persist();
  }

  /// Replaces all the secrets whose key starts with [prefix].
  Future<void> setAll(String prefix, Map<String, String> values) async {
    _requireUnlocked();
    _secrets.removeWhere((k, _) => k.startsWith(prefix));
    values.forEach((k, v) {
      if (v.isNotEmpty) _secrets['$prefix$k'] = v;
    });
    await _persist();
  }

  Map<String, String> withPrefix(String prefix) => {
    for (final e in _secrets.entries)
      if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
  };

  Future<void> removePrefix(String prefix) async {
    _requireUnlocked();
    final before = _secrets.length;
    _secrets.removeWhere((k, _) => k.startsWith(prefix));
    if (_secrets.length != before) await _persist();
  }

  int get length => _secrets.length;

  // -------------------------------------------------------------------------

  void _requireUnlocked() {
    if (_key == null) throw VaultException('Il vault delle credenziali è bloccato.');
  }

  void _decryptAll() {
    final data = _header['data'];
    if (data is! Map) {
      _secrets = {};
      return;
    }
    final plain = _decrypt(_key!, data.cast());
    _secrets = (jsonDecode(utf8.decode(plain)) as Map).map((k, v) => MapEntry(k as String, v as String));
  }

  Future<void> _persist() async {
    _header['data'] = _encrypt(_key!, utf8.encode(jsonEncode(_secrets)));
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(_header));
    await _restrict(tmp);
    await tmp.rename(_file.path);
  }

  Future<void> _writeKeyFile(Uint8List key) async {
    await _keyFile.writeAsString(base64Encode(key));
    await _restrict(_keyFile);
  }

  static Future<void> _restrict(File f) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', f.path]);
    } catch (_) {}
  }

  static Map<String, String> _encrypt(Uint8List key, List<int> plain) {
    final nonce = _randomBytes(12);
    final c = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    final out = c.process(Uint8List.fromList(plain));
    return {'nonce': base64Encode(nonce), 'ct': base64Encode(out)};
  }

  static Uint8List _decrypt(Uint8List key, Map<String, Object?> box) {
    final nonce = base64Decode(box['nonce'] as String);
    final ct = base64Decode(box['ct'] as String);
    final c = GCMBlockCipher(AESEngine())..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    return c.process(ct);
  }

  static final _rnd = Random.secure();

  static Uint8List _randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _rnd.nextInt(256)));

  /// PBKDF2-HMAC-SHA256, computed in a helper isolate (it takes a moment).
  static Future<Uint8List> deriveKey(String password, List<int> salt, int iterations) =>
      Isolate.run(() {
        final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
          ..init(Pbkdf2Parameters(Uint8List.fromList(salt), iterations, 32));
        return d.process(Uint8List.fromList(utf8.encode(password)));
      });
}
