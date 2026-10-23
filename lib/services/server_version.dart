/// Version of the database server, parsed from the ODBC `SQL_DBMS_VER`
/// string (or the version reported by a native driver).
///
/// Drivers format it in many ways: `16.00.4135` (SQL Server),
/// `16.4` (PostgreSQL), `10.11.6-MariaDB-1:10.11.6+maria~ubu2204`,
/// `19.00.0000` (Oracle), `WI-V5.0.0.1306 Firebird 5.0` (Firebird), so only
/// the first `major.minor[.patch]` group is used.
class ServerVersion implements Comparable<ServerVersion> {
  const ServerVersion(this.major, [this.minor = 0, this.patch = 0]);

  final int major;
  final int minor;
  final int patch;

  static final _number = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?');

  /// Null when [text] contains no version number.
  static ServerVersion? tryParse(String? text) {
    if (text == null) return null;
    final m = _number.firstMatch(text);
    if (m == null) return null;
    return ServerVersion(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3) ?? '0'));
  }

  bool atLeast(int major, [int minor = 0, int patch = 0]) => compareTo(ServerVersion(major, minor, patch)) >= 0;

  @override
  int compareTo(ServerVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is ServerVersion && other.major == major && other.minor == minor && other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}
