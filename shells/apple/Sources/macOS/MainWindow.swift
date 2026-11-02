import AppKit

/// The app's one window, drawn as docs/design.md rule 12 says: no title text, no title bar tone, the page up to the top
/// edge and the traffic lights centred in its 52 px header rows. The page says which parts of its headers move the
/// window (shell.dragRegions).
@MainActor
final class MainWindow: NSWindow, ShellHost {
    /// Height of the page's top header rows; the traffic lights are centred in it. Mirrors `titleBarHeight` in
    /// ui/src/app/window_chrome.tsx.
    private static let titleBarHeight: CGFloat = 52

    /// Left edge of the close button.
    private static let trafficLightsX: CGFloat = 20

    /// Space between the zoom button and a header row's content.
    private static let afterTrafficLights: CGFloat = 12

    private let shell: Shell

    /// AppKit's space between the traffic lights, which differs between macOS versions; measured on the window's own.
    private var trafficLightsSpacing: CGFloat = 0

    /// The zoom button's right edge.
    private var trafficLightsEnd: CGFloat = 0

    /// The traffic lights while the window is full screen; see `showFullScreenTrafficLights`.
    private var fullScreenTrafficLights: NSView?

    /// The window that keeps the screen refreshing for this window's frames while it is full screen; see
    /// `showRefreshKeeper`.
    private var refreshKeeper: NSWindow?

    /// The parts of the page's headers that move the window, and the controls in them that do not, in the page's CSS
    /// px from the top-left corner.
    private var drag: [CGRect] = []
    private var noDrag: [CGRect] = []

    init(shell: Shell) {
        self.shell = shell
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        // The Window menu, Mission Control and the Dock name it; the title bar shows no text.
        title = "ompanion"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = Shell.background
        contentMinSize = NSSize(width: 360, height: 480)
        contentView = shell.webView
        center()
        shell.host = self

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didResize), name: NSWindow.didResizeNotification, object: self)
        // Full screen hides AppKit's title bar until the pointer reaches the top edge. Copies of the traffic lights stay
        // on the header row where the window had them, so the header keeps its room; the page only stops its header
        // rows from moving the window. The copies go once the window is out, where AppKit's own sit in the same place.
        center.addObserver(
            self, selector: #selector(didEnterFullScreen), name: NSWindow.didEnterFullScreenNotification, object: self)
        center.addObserver(
            self, selector: #selector(willExitFullScreen), name: NSWindow.willExitFullScreenNotification, object: self)
        center.addObserver(
            self, selector: #selector(didExitFullScreen), name: NSWindow.didExitFullScreenNotification, object: self)
        // The window lives as long as the app, so the monitor is never removed.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self, self.movesWindow(event) else { return event }
            return nil
        }
        layoutTrafficLights()
    }

    func answer(_ method: String, _ params: Params) async throws -> [String: Any] {
        switch method {
        case "shell.insets":
            return ["top": 0, "right": 0, "bottom": 0, "left": 0, "keyboard": 0]
        case "shell.titleBar":
            return titleBar(fullScreen: styleMask.contains(.fullScreen))
        case "shell.dragRegions":
            drag = try params.rects("drag")
            noDrag = try params.rects("noDrag")
            return [:]
        case "shell.pickFiles":
            return ["paths": try await pickFiles(params)]
        case "shell.clipboardFiles":
            // File URLs only: a link a browser copied is a URL too.
            let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            return ["paths": (urls as? [URL] ?? []).map(\.path)]
        default:
            throw ShellError.unknownMethod(method)
        }
    }

    /// The open panel, as a sheet of the window: files, or with `directory` folders; empty when cancelled.
    private func pickFiles(_ params: Params) async throws -> [String] {
        let panel = NSOpenPanel()
        let directory = try params.bool("directory")
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = try params.bool("multiple")
        if let start = try params.optionalString("startIn") {
            panel.directoryURL = URL(fileURLWithPath: (start as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard await panel.beginSheetModal(for: self) == .OK else { return [] }
        return panel.urls.map(\.path)
    }

    func save(_ file: URL, as name: String) async throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard await panel.beginSheetModal(for: self) == .OK, let target = panel.url else { return false }
        // The panel has asked before replacing a file that is there.
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: file, to: target)
        return true
    }

    private func titleBar(fullScreen: Bool) -> [String: Any] {
        layoutTrafficLights()
        return [
            "height": Self.titleBarHeight,
            "leadingInset": (trafficLightsEnd + Self.afterTrafficLights).rounded(),
            "fullScreen": fullScreen,
        ]
    }

    @objc private func didResize() {
        layoutTrafficLights()
    }

    @objc private func didEnterFullScreen() {
        showFullScreenTrafficLights()
        showRefreshKeeper()
        shell.emit("shell.titleBar", titleBar(fullScreen: true))
    }

    @objc private func willExitFullScreen() {
        hideRefreshKeeper()
        shell.emit("shell.titleBar", titleBar(fullScreen: false))
    }

    @objc private func didExitFullScreen() {
        fullScreenTrafficLights?.removeFromSuperview()
        fullScreenTrafficLights = nil
        layoutTrafficLights()
    }

    /// Puts a one-point window with 1/255 white in the window's bottom-right corner. Measured with the Flutter app on
    /// macOS 27 with a ProMotion display: in full screen, once the user has typed, the window server stops refreshing
    /// the screen for the frames this window commits and refreshes at its 10 Hz floor until a click, so scrolling shows
    /// 10 of 120 frames a second. Any other window with visible content on the screen keeps it refreshing for every
    /// frame; a clear one does not count. WebKit paces its frames as that app did, with a CVDisplayLink that asks the
    /// window server for no frame rate, and commits them as Core Animation transactions.
    private func showRefreshKeeper() {
        guard refreshKeeper == nil else { return }
        let keeper = NSWindow(
            contentRect: NSRect(x: frame.maxX - 1, y: frame.minY, width: 1, height: 1), styleMask: .borderless,
            backing: .buffered, defer: false)
        keeper.isReleasedWhenClosed = false
        keeper.isOpaque = false
        keeper.hasShadow = false
        keeper.ignoresMouseEvents = true
        keeper.isExcludedFromWindowsMenu = true
        keeper.backgroundColor = NSColor.white.withAlphaComponent(1 / 255)
        addChildWindow(keeper, ordered: .above)
        refreshKeeper = keeper
    }

    private func hideRefreshKeeper() {
        guard let keeper = refreshKeeper else { return }
        removeChildWindow(keeper)
        keeper.orderOut(nil)
        refreshKeeper = nil
    }

    /// A mouse-down in a drag region of the page's headers moves the window, or on a double click does what the user
    /// set for title bars. Not in full screen, where the window stays put, nor on the title bar's own buttons.
    private func movesWindow(_ event: NSEvent) -> Bool {
        guard !styleMask.contains(.fullScreen), let content = contentView,
              content.superview?.hitTest(event.locationInWindow)?.isDescendant(of: content) == true
        else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        let css = CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
        guard drag.contains(where: { $0.contains(css) }), !noDrag.contains(where: { $0.contains(css) }) else {
            return false
        }
        if event.clickCount == 2 {
            doubleClickTitleBar()
        } else {
            performDrag(with: event)
        }
        return true
    }

    // AppKit lays the title bar out again on its own (on show, on key changes); the lights go back where the app wants
    // them after each pass.
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTrafficLights()
    }

    /// Makes the title bar as tall as the page's header rows and centres the traffic lights in it. Full screen shows
    /// AppKit's own title bar, which is left alone. While the full screen copies are in the window,
    /// `standardWindowButton` returns them instead of AppKit's; they are gone before the window is out of full screen.
    private func layoutTrafficLights() {
        guard !styleMask.contains(.fullScreen), fullScreenTrafficLights == nil,
              let close = standardWindowButton(.closeButton),
              let miniaturize = standardWindowButton(.miniaturizeButton),
              let zoom = standardWindowButton(.zoomButton),
              let container = close.superview?.superview
        else { return }
        let height = Self.titleBarHeight
        var frame = container.frame
        if frame.height != height || frame.origin.y != self.frame.height - height {
            frame.size.height = height
            frame.origin.y = self.frame.height - height
            container.frame = frame
        }
        let spacing = miniaturize.frame.minX - close.frame.minX
        for (index, button) in [close, miniaturize, zoom].enumerated() {
            let origin = NSPoint(
                x: Self.trafficLightsX + CGFloat(index) * spacing,
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
        let height = Self.titleBarHeight
        let size = buttons[0].frame.size
        let y = ((height - size.height) / 2).rounded()
        let lights = NSView(
            frame: NSRect(
                x: Self.trafficLightsX, y: content.isFlipped ? y : content.bounds.height - height + y,
                width: 2 * trafficLightsSpacing + size.width, height: size.height))
        lights.autoresizingMask = content.isFlipped ? [.maxYMargin] : [.minYMargin]
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
}
