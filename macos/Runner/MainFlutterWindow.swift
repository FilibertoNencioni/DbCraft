import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Unified title bar: Flutter draws the toolbar next to the traffic lights.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    // An empty unified toolbar makes AppKit center the traffic lights on the
    // 52pt Flutter toolbar, as in Finder or Mail, in every window state.
    self.toolbar = NSToolbar(identifier: "MainToolbar")
    self.toolbarStyle = .unified
    self.delegate = self
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
      case "isKeyWindow":
        result(self.isKeyWindow)
      case "accentColor":
        result(Self.accentArgb())
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
    // Inactive windows dim selections and the default button, as AppKit does.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: self, queue: .main
    ) { [weak self] _ in self?.windowChannel?.invokeMethod("windowKey", arguments: true) }
    NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: self, queue: .main
    ) { [weak self] _ in self?.windowChannel?.invokeMethod("windowKey", arguments: false) }
    // The user's accent color (System Settings > Appearance).
    NotificationCenter.default.addObserver(
      forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.windowChannel?.invokeMethod("accentColor", arguments: Self.accentArgb()) }

    disableNativeTitleBarDoubleClick()
    NotificationCenter.default.addObserver(
      forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in self?.disableNativeTitleBarDoubleClick() }

    super.awakeFromNib()
  }

  /// In full screen the toolbar would stay pinned and opaque over the top of
  /// the Flutter content; let it slide in with the menu bar instead.
  func window(
    _ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
  ) -> NSApplication.PresentationOptions {
    proposedOptions.union(.autoHideToolbar)
  }

  /// AppKit zooms on any double click in the title-bar strip, even one that
  /// lands on a Flutter control there (two quick clicks on the sidebar toggle
  /// zoomed the window). Flutter already detects title-bar double clicks on
  /// the empty parts of the toolbar, so the native recognizer is switched off.
  private func disableNativeTitleBarDoubleClick() {
    for case let click as NSClickGestureRecognizer in contentView?.superview?.gestureRecognizers ?? []
    where click.numberOfClicksRequired == 2
      && click.action.map(NSStringFromSelector)?.contains("TitledFrameDoubleClick") == true
    {
      click.isEnabled = false
    }
  }

  /// The system accent color as 0xAARRGGBB in sRGB.
  private static func accentArgb() -> Int {
    guard let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return 0xFF007AFF }
    func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
    return (byte(c.alphaComponent) << 24) | (byte(c.redComponent) << 16) | (byte(c.greenComponent) << 8)
      | byte(c.blueComponent)
  }
}
