import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Unified title bar: Flutter draws the toolbar next to the traffic lights.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = false
    self.minSize = NSSize(width: 960, height: 600)
    if let screen = NSScreen.main {
      let visible = screen.visibleFrame
      let size = NSSize(width: min(1440, visible.width * 0.9), height: min(900, visible.height * 0.9))
      self.setFrame(
        NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
               width: size.width, height: size.height),
        display: true)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "dbcraft/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "startDrag":
        if let event = NSApp.currentEvent {
          self.performDrag(with: event)
        }
        result(nil)
      case "titleBarDoubleClick":
        // Honour the user's "double-click a window's title bar to" preference.
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        if action == "Minimize" {
          self.performMiniaturize(nil)
        } else if action != "None" {
          self.performZoom(nil)
        }
        result(nil)
      case "isFullScreen":
        result(self.styleMask.contains(.fullScreen))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = channel

    NotificationCenter.default.addObserver(
      forName: NSWindow.willEnterFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in self?.windowChannel?.invokeMethod("fullScreen", arguments: true) }
    NotificationCenter.default.addObserver(
      forName: NSWindow.willExitFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in self?.windowChannel?.invokeMethod("fullScreen", arguments: false) }

    super.awakeFromNib()
  }
}
