import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  /// Height of the app's top header rows (the sidebar's, the chat's, the dock's); the traffic lights are centred in it.
  /// Mirrors `titleBarHeight` in lib/app/window_chrome.dart.
  private static let titleBarHeight: CGFloat = 52

  /// Left edge of the close button; the app's header rows start their content after the zoom button, whose right edge
  /// Dart asks for (`state`).
  private static let trafficLightsX: CGFloat = 20

  private var chrome: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // The app draws the whole window: no title text, no title bar tone; the traffic lights float over the sidebar's
    // header row.
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let chrome = FlutterMethodChannel(
      name: "ompanion/window_chrome", binaryMessenger: flutterViewController.engine.binaryMessenger)
    chrome.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "state":
        self.layoutTrafficLights()
        result([
          "fullScreen": self.styleMask.contains(.fullScreen),
          "trafficLightsEnd": Double(self.standardWindowButton(.zoomButton)?.frame.maxX ?? 0),
        ])
      case "doubleClickTitleBar":
        self.doubleClickTitleBar()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.chrome = chrome

    let center = NotificationCenter.default
    center.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
      self?.layoutTrafficLights()
    }
    // Full screen hides the lights with the title bar. Dart drops the room it keeps for them once the window is full
    // screen (an attempt can fail, and then nothing changes), and restores it as the window starts to leave.
    center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.chrome?.invokeMethod("fullScreen", arguments: true)
    }
    center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.chrome?.invokeMethod("fullScreen", arguments: false)
    }
    center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.layoutTrafficLights()
    }

    super.awakeFromNib()
    layoutTrafficLights()
  }

  // AppKit lays the title bar out again on its own (on show, on key changes); the lights go back where the app wants
  // them after each pass.
  override func layoutIfNeeded() {
    super.layoutIfNeeded()
    layoutTrafficLights()
  }

  /// Makes the title bar as tall as the app's header rows and centres the traffic lights in it. Full screen shows
  /// AppKit's own title bar, which is left alone.
  private func layoutTrafficLights() {
    guard !styleMask.contains(.fullScreen),
      let close = standardWindowButton(.closeButton),
      let miniaturize = standardWindowButton(.miniaturizeButton),
      let zoom = standardWindowButton(.zoomButton),
      let container = close.superview?.superview
    else { return }
    let height = MainFlutterWindow.titleBarHeight
    var frame = container.frame
    if frame.height != height || frame.origin.y != self.frame.height - height {
      frame.size.height = height
      frame.origin.y = self.frame.height - height
      container.frame = frame
    }
    let spacing = miniaturize.frame.minX - close.frame.minX
    for (index, button) in [close, miniaturize, zoom].enumerated() {
      let origin = NSPoint(
        x: MainFlutterWindow.trafficLightsX + CGFloat(index) * spacing,
        y: ((height - button.frame.height) / 2).rounded())
      if button.frame.origin != origin { button.setFrameOrigin(origin) }
    }
  }

  /// What a double click on a title bar does, as the user set it in System Settings > Desktop & Dock.
  private func doubleClickTitleBar() {
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize":
      performMiniaturize(nil)
    case "None":
      break
    default:
      performZoom(nil)
    }
  }

  // Keeps the window hidden until Dart applies its size and calls show(), so it does not flash at the
  // storyboard's default frame.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
