// Built-in ("native") drivers that do not need an ODBC driver: they speak the
// database wire protocol or REST API directly from Dart.
import 'package:flutter/material.dart';

import 'db_session.dart';

/// Extra connection option shown in the connection dialog for a native
/// driver. Values are stored in ConnectionConfig.extraParams (or in the vault
/// when [secret] is true).
class NativeDriverField {
  const NativeDriverField(
    this.key,
    this.label, {
    this.hint = '',
    this.help,
    this.secret = false,
    this.defaultValue = '',
    this.options = const [],
    this.multiline = false,
    this.file = false,
  });

  final String key;
  final String label;
  final String hint;
  final String? help;

  /// Stored encrypted in the vault (keys, tokens, client secrets).
  final bool secret;
  final String defaultValue;

  /// When not empty the field is a drop-down with these values.
  final List<String> options;
  final bool multiline;

  /// The value is a local file path (a "Sfoglia…" button is shown).
  final bool file;
}

/// Parameters passed to [NativeDriver.open].
class NativeConnectParams {
  const NativeConnectParams({
    required this.host,
    required this.port,
    required this.database,
    required this.user,
    required this.password,
    required this.options,
    this.connectionUri = '',
    this.loginTimeoutSec = 15,
    this.readOnly = false,
  });

  final String host;
  final String port;
  final String database;
  final String user;
  final String password;

  /// Driver specific options (keys of [NativeDriver.fields], secrets included).
  final Map<String, String> options;

  /// Optional full URI (e.g. mongodb+srv://…, redis://…) that overrides
  /// host/port/database/user.
  final String connectionUri;
  final int loginTimeoutSec;
  final bool readOnly;

  String option(String key, [String def = '']) {
    final v = options[key];
    return v == null || v.isEmpty ? def : v;
  }

  bool flag(String key) => const {'1', 'true', 'yes', 'on', 'sì', 'si'}.contains(option(key).toLowerCase());
}

abstract class NativeDriver {
  const NativeDriver();

  /// Stable identifier stored in the connection configuration.
  String get id;
  String get label;
  String get description;
  IconData get icon;
  Color get color;
  String get defaultPort;

  /// 'sql', 'cql', 'mongo' or 'redis': drives syntax help and the editor.
  String get queryLanguage;

  /// Which standard fields the connection dialog shows.
  bool get usesHost => true;
  bool get usesDatabase => true;
  bool get usesUser => true;
  bool get usesPassword => true;

  /// Supports a connection URI (mongodb://, redis://…).
  bool get usesUri => false;
  String get uriHint => '';
  String get databaseLabel => 'Database';
  String get databaseHint => '';

  List<NativeDriverField> get fields => const [];

  /// Example statement inserted in a new editor.
  String get sampleQuery => '';

  Future<DbSession> open(NativeConnectParams params);
}
