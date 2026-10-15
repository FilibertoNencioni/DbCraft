// mongodb:// and mongodb+srv:// connection string parsing.
import '../common/native_exception.dart';

class MongoHost {
  const MongoHost(this.host, this.port);
  final String host;
  final int port;

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is MongoHost && other.host.toLowerCase() == host.toLowerCase() && other.port == port;
  @override
  int get hashCode => Object.hash(host.toLowerCase(), port);

  /// Parses `host[:port]` / `[v6]:port`.
  static MongoHost parse(String s, {int defaultPort = 27017}) {
    var t = s.trim();
    if (t.startsWith('[')) {
      final end = t.indexOf(']');
      if (end < 0) throw NativeDbException('Host IPv6 non valido: "$s"');
      final host = t.substring(1, end);
      final rest = t.substring(end + 1);
      return MongoHost(host, rest.startsWith(':') ? int.tryParse(rest.substring(1)) ?? defaultPort : defaultPort);
    }
    final i = t.lastIndexOf(':');
    if (i > 0 && t.indexOf(':') == i) {
      final port = int.tryParse(t.substring(i + 1));
      if (port == null) throw NativeDbException('Porta non valida in "$s"');
      return MongoHost(t.substring(0, i), port);
    }
    return MongoHost(t, defaultPort);
  }
}

class MongoUri {
  MongoUri({
    required this.srv,
    required this.hosts,
    this.user,
    this.password,
    this.database,
    Map<String, String>? options,
  }) : options = options ?? {};

  final bool srv;
  final List<MongoHost> hosts;
  final String? user;
  final String? password;
  final String? database;

  /// Query options with lower-case keys.
  final Map<String, String> options;

  String? option(String key) => options[key.toLowerCase()];

  static MongoUri parse(String uri) {
    final u = uri.trim();
    final bool srv;
    String rest;
    if (u.startsWith('mongodb+srv://')) {
      srv = true;
      rest = u.substring(14);
    } else if (u.startsWith('mongodb://')) {
      srv = false;
      rest = u.substring(10);
    } else {
      throw NativeDbException('URI MongoDB non valido: deve iniziare con mongodb:// o mongodb+srv://');
    }
    String? query;
    final q = rest.indexOf('?');
    if (q >= 0) {
      query = rest.substring(q + 1);
      rest = rest.substring(0, q);
    }
    String? user, password;
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      final cred = rest.substring(0, at);
      rest = rest.substring(at + 1);
      final c = cred.indexOf(':');
      user = Uri.decodeComponent(c < 0 ? cred : cred.substring(0, c));
      if (c >= 0) password = Uri.decodeComponent(cred.substring(c + 1));
    }
    String? database;
    final slash = rest.indexOf('/');
    if (slash >= 0) {
      final db = Uri.decodeComponent(rest.substring(slash + 1));
      if (db.isNotEmpty) database = db;
      rest = rest.substring(0, slash);
    }
    if (rest.isEmpty) throw NativeDbException('URI MongoDB senza host');
    final hosts = [
      for (final h in rest.split(','))
        if (h.trim().isNotEmpty) MongoHost.parse(Uri.decodeComponent(h)),
    ];
    if (srv && (hosts.length != 1 || rest.contains(':'))) {
      throw NativeDbException('mongodb+srv:// richiede un solo nome host senza porta');
    }
    final options = <String, String>{};
    if (query != null && query.isNotEmpty) {
      for (final part in query.split(RegExp('[&;]'))) {
        if (part.isEmpty) continue;
        final i = part.indexOf('=');
        final k = Uri.decodeQueryComponent(i < 0 ? part : part.substring(0, i)).toLowerCase();
        final v = i < 0 ? '' : Uri.decodeQueryComponent(part.substring(i + 1));
        options[k] = v;
      }
    }
    return MongoUri(srv: srv, hosts: hosts, user: user, password: password, database: database, options: options);
  }

  /// URI with the password masked.
  static String mask(String uri) =>
      uri.replaceFirstMapped(RegExp(r'^(mongodb(?:\+srv)?://[^:/@]+:)([^@]*)@'), (m) => '${m.group(1)}****@');
}
