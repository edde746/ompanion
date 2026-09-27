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

  /// AppKit's space between the traffic lights, which differs between macOS versions; measured on the window's own.
  private var trafficLightsSpacing: CGFloat = 0

  /// The zoom button's right edge.
  private var trafficLightsEnd: CGFloat = 0

  /// The traffic lights while the window is full screen; see `showFullScreenTrafficLights`.
  private var fullScreenTrafficLights: NSView?

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
          "trafficLightsEnd": Double(self.trafficLightsEnd),
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
    // Full screen hides AppKit's title bar until the pointer reaches the top edge. Copies of the traffic lights stay on
    // the header row where the window had them, so the header keeps its room; Dart only stops the header rows from
    // moving the window. The copies go once the window is out, where AppKit's own sit in the same place, so leaving
    // shows no jump, and an attempt to leave that fails keeps them.
    center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.showFullScreenTrafficLights()
      self?.chrome?.invokeMethod("fullScreen", arguments: true)
    }
    center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.chrome?.invokeMethod("fullScreen", arguments: false)
    }
    center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.fullScreenTrafficLights?.removeFromSuperview()
      self?.fullScreenTrafficLights = nil
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
  /// AppKit's own title bar, which is left alone. While the full screen copies are in the window,
  /// `standardWindowButton` returns them instead of AppKit's; they are gone before the window is out of full screen.
  private func layoutTrafficLights() {
    guard !styleMask.contains(.fullScreen), fullScreenTrafficLights == nil,
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
    trafficLightsSpacing = spacing
    trafficLightsEnd = zoom.frame.maxX
  }

  /// Puts AppKit's standard traffic lights (`NSWindow.standardWindowButton(_:for:)`: they act on the window and grey
  /// out while it is not key, as the title bar's do) over the header row, where `layoutTrafficLights` puts the title
  /// bar's. AppKit draws their symbols on hover only for buttons in its own title bar, so these show none.
  private func showFullScreenTrafficLights() {
    guard fullScreenTrafficLights == nil, let content = contentView else { return }
    let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    let buttons = types.compactMap { NSWindow.standardWindowButton($0, for: styleMask) }
    guard buttons.count == types.count else { return }
    // A full screen window cannot be minimized; AppKit's full screen title bar greys the button out as well.
    buttons[1].isEnabled = false
    let height = MainFlutterWindow.titleBarHeight
    let size = buttons[0].frame.size
    let lights = NSView(
      frame: NSRect(
        x: MainFlutterWindow.trafficLightsX,
        y: content.bounds.height - height + ((height - size.height) / 2).rounded(),
        width: 2 * trafficLightsSpacing + size.width, height: size.height))
    lights.autoresizingMask = [.minYMargin]
    for (index, button) in buttons.enumerated() {
      button.setFrameOrigin(NSPoint(x: CGFloat(index) * trafficLightsSpacing, y: 0))
      lights.addSubview(button)
    }
    content.addSubview(lights)
    fullScreenTrafficLights = lights
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
