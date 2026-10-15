import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  static func main() {
    OpenSslRedirect.applyOrRelaunch()
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Microsoft's SQL Server ODBC drivers (msodbcsql17/18) dlopen OpenSSL from
/// Homebrew's unversioned `opt/openssl` link and only support OpenSSL 1.x and
/// 3.x. Homebrew drops that link or moves it to openssl@4 on upgrades, and
/// fixing it by hand only lasts until the next `brew upgrade`. Instead, when
/// the link is broken, relaunch once with DYLD_LIBRARY_PATH set to openssl@3:
/// dyld then serves the driver's dlopen by file name from there. dyld reads
/// the variable only at launch, hence the relaunch.
enum OpenSslRedirect {
  /// Set on the relaunched process to the openssl@3 lib directory; the Dart
  /// side reads it to know the redirect is active.
  static let marker = "DBCRAFT_OPENSSL_LIB"
  private static let savedPath = "DBCRAFT_SAVED_DYLD_LIBRARY_PATH"
  private static let prefixes = ["/opt/homebrew", "/usr/local"]

  static func applyOrRelaunch() {
    let env = ProcessInfo.processInfo.environment
    if env[marker] != nil {
      // Relaunched: dyld already has the redirect, don't pass it on to child processes.
      if let saved = env[savedPath] { setenv("DYLD_LIBRARY_PATH", saved, 1) } else { unsetenv("DYLD_LIBRARY_PATH") }
      unsetenv(savedPath)
      return
    }
    guard let dir = openSsl3Dir(), let exe = Bundle.main.executablePath else { return }

    setenv(marker, dir, 1)
    if let current = env["DYLD_LIBRARY_PATH"], !current.isEmpty {
      setenv(savedPath, current, 1)
      setenv("DYLD_LIBRARY_PATH", "\(dir):\(current)", 1)
    } else {
      setenv("DYLD_LIBRARY_PATH", dir, 1)
    }
    execv(exe, CommandLine.unsafeArgv)

    // execv only returns on failure: carry on without the redirect.
    unsetenv(marker)
    if let saved = env[savedPath] { setenv("DYLD_LIBRARY_PATH", saved, 1) } else { unsetenv("DYLD_LIBRARY_PATH") }
    unsetenv(savedPath)
  }

  /// openssl@3's lib directory when a Homebrew prefix has a SQL Server driver
  /// but its `opt/openssl` link is missing or not OpenSSL 1.x/3.x.
  private static func openSsl3Dir() -> String? {
    let fm = FileManager.default
    for prefix in prefixes {
      guard fm.fileExists(atPath: "\(prefix)/opt/msodbcsql18") || fm.fileExists(atPath: "\(prefix)/opt/msodbcsql17")
      else { continue }

      let libssl = "\(prefix)/opt/openssl/lib/libssl.dylib"
      if fm.fileExists(atPath: libssl) {
        let name = URL(fileURLWithPath: libssl).resolvingSymlinksInPath().lastPathComponent
        if name.hasPrefix("libssl.1.") || name.hasPrefix("libssl.3.") { continue }
      }

      let dir = "\(prefix)/opt/openssl@3/lib"
      if fm.fileExists(atPath: "\(dir)/libssl.3.dylib") { return dir }
    }
    return nil
  }
}
