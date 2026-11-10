import Ompcore
import UserNotifications
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The window's side of the shell services (docs/contracts/bridge.md, Shell services): macOS's MainWindow, iOS's
/// WebViewController.
@MainActor
protocol ShellHost: AnyObject {
    /// Answers shell.insets, and on macOS shell.titleBar, shell.dragRegions, shell.pickFiles and shell.clipboardFiles.
    func answer(_ method: String, _ params: Params) async throws -> [String: Any]
    /// Offers `file` to the user under `name`: the save panel, iOS's share sheet; true when the user saved it.
    func save(_ file: URL, as name: String) async throws -> Bool
}

/// The page and its bridge to the core (docs/contracts/bridge.md, Shells): a WKWebView showing the bundled `ui` folder
/// at app://ompanion/, with `window.webkit.messageHandlers.core` wired to the process's one core. Requests for shell.*
/// methods never reach the core: the shell answers them (Services.swift, the host for the window's own).
@MainActor
final class Shell: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let startURL = URL(string: "app://ompanion/index.html")!
    /// The page the shell shows: index.html, with the query OMPCORE_PAGE_QUERY names when set (`shot.sh`: a gallery
    /// page instead of the app).
    private static let pageURL: URL = {
        guard let query = ProcessInfo.processInfo.environment["OMPCORE_PAGE_QUERY"] else { return startURL }
        var components = URLComponents(url: startURL, resolvingAgainstBaseURL: false)!
        components.query = query
        return components.url!
    }()
    /// The bundle id; it names the app's folders and its Keychain service.
    nonisolated static let appID = "com.edde746.ompanion"

    /// The window's and the web view's colour until the page paints: the app's background, black in dark mode and
    /// white in light, so a launch shows no white flash.
    #if os(macOS)
    static let background = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white }
    #else
    static let background = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
    #endif

    /// OMPCORE_SNAPSHOT=<file.png>: a picture of the window as it is when the page asks to exit (`smoke.sh`, `shot.sh`);
    /// with it set the page may also ask for pictures with shell.snapshot (store screenshots).
    static let snapshotPath = ProcessInfo.processInfo.environment["OMPCORE_SNAPSHOT"]

    let webView: WKWebView
    weak var host: ShellHost?
    #if os(iOS)
    let push = Push()
    #endif
    private let files: SchemeHandler
    /// Made first, so its shell mark is the shell's first code.
    let timing = LaunchTiming()
    /// Whether the loaded page has sent its first message: until then it has no receiver for events.
    private var pageReady = false
    /// Notification taps that came while no page was ready; they go after its first message (docs/contracts/bridge.md).
    private var pendingTaps: [String] = []
    /// Counts the pages the core has served: each has its own listener, and what an older one still has queued for
    /// the page (core messages, shell answers) never reaches a newer page, whose request ids start over.
    private var generation = 0
    /// Whether the core was started for the page that commits next: at launch, and after the web content process ended.
    private var coreIsFresh = false

    override init() {
        guard let root = Bundle.main.url(forResource: "ui", withExtension: nil) else {
            fatalError("the app bundle has no ui folder")
        }
        let data = Self.appFolder(.applicationSupportDirectory)
        let cache = Self.appFolder(.cachesDirectory)
        files = SchemeHandler(root: root, cache: cache)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(files, forURLScheme: "app")
        #if os(macOS)
        let fileDrops = FileDropWebView(frame: .zero, configuration: configuration)
        webView = fileDrops
        #else
        webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        timing.mark("webviewMs")
        super.init()
        #if os(macOS)
        fileDrops.shell = self
        #else
        push.shell = self
        #endif
        // The content controller keeps the handler: the shell lives as long as the process.
        webView.configuration.userContentController.add(self, name: "core")
        // OMPCORE_PAGE_SCRIPT=<JavaScript>: runs in the page once it has loaded (`shot.sh`: a user's steps to the screen
        // it shoots).
        if let script = ProcessInfo.processInfo.environment["OMPCORE_PAGE_SCRIPT"] {
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        #if DEBUG
        if #available(macOS 13.3, iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
        #if os(macOS)
        // Transparent until the page paints, over the window's background; WebKit has no public switch for it on macOS.
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = Self.background
        webView.scrollView.backgroundColor = Self.background
        // viewport-fit=cover: the page lays out under the notch and home indicator with env(safe-area-inset-*).
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            // Nor does the system blur the page's content under the status bar and home indicator.
            webView.scrollView.topEdgeEffect.isHidden = true
            webView.scrollView.bottomEdgeEffect.isHidden = true
        }
        #endif
        webView.load(URLRequest(url: Self.pageURL))
        timing.mark("loadMs")
        DispatchQueue.main.async { [timing] in timing.mark("mainQueueMs") }
        // The rest overlaps the page's load: its first request needs this thread, and by then the core runs.
        Self.prepareCoreFolders(data: data, cache: cache)
        timing.mark("coreEnvMs")
        startCore()
        timing.mark("coreStartMs")
        UNUserNotificationCenter.current().delegate = self
        #if os(macOS)
        let active = NSApplication.didBecomeActiveNotification, inactive = NSApplication.didResignActiveNotification
        #else
        let active = UIApplication.didBecomeActiveNotification, inactive = UIApplication.willResignActiveNotification
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: active, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive), name: inactive, object: nil)
    }

    /// The app's own folder in one of the user's system folders.
    static func appFolder(_ folder: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: folder, in: .userDomainMask)[0].appendingPathComponent(appID, isDirectory: true)
    }

    /// Creates the core's data and cache folders and tells the core where they are (docs/contracts/bridge.md, Cache
    /// files).
    private static func prepareCoreFolders(data: URL, cache: URL) {
        for (name, folder) in [("OMPCORE_DATA_DIR", data), ("OMPCORE_CACHE_DIR", cache)] {
            var error: NSError?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                fatalError("creating \(folder.path) failed: \(error)")
            }
            guard OmpcoreSetEnv(name, folder.path, &error) else {
                fatalError("setting \(name) failed: \(error?.localizedDescription ?? "no error")")
            }
        }
    }

    /// Points the core at a new page. The core releases what the previous page opened (docs/contracts/bridge.md, Core
    /// bindings).
    private func startCore() {
        generation += 1
        coreIsFresh = true
        OmpcoreStart(PageListener(shell: self, generation: generation))
    }

    fileprivate func deliver(_ message: String, from generation: Int) {
        guard generation == self.generation else { return }
        deliver(message)
    }

    private func deliver(_ message: String) {
        webView.evaluateJavaScript("window.ompCore.receive(" + message + ")") { _, error in
            // Messages emitted before the page defined window.ompCore, or while it reloads, are dropped
            // (docs/contracts/bridge.md).
            if let error {
                NSLog("shell: delivering a message to the page failed: %@", error.localizedDescription)
            }
        }
    }

    /// Sends the page a shell event; false when it was dropped. Before the loaded page's first message nothing receives
    /// it, so it is dropped: the page asks for the state it carries when it starts.
    @discardableResult
    func emit(_ event: String, _ params: [String: Any]) -> Bool {
        guard pageReady else { return false }
        deliver(Self.json(["event": event, "params": params]))
        return true
    }

    /// Sends a `shell.notificationTap` event, after the page's first message when no page is ready yet.
    func sendTap(_ message: String) {
        if pageReady {
            deliver(message)
        } else {
            pendingTaps.append(message)
        }
    }

    @objc private func becameActive() {
        emit("shell.appState", ["active": true])
    }

    @objc private func resignedActive() {
        emit("shell.appState", ["active": false])
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Every frame sees the handler; only the app's own page, never the agent-HTML iframe, reaches the core.
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "app", origin.host == "ompanion" else {
            NSLog("shell: dropped a core message from %@://%@", origin.protocol, origin.host)
            return
        }
        guard let text = message.body as? String else {
            NSLog("shell: dropped a core message that is not text: %@", String(describing: type(of: message.body)))
            return
        }
        if !pageReady {
            pageReady = true
            pendingTaps.forEach(deliver)
            pendingTaps.removeAll()
        }
        // Most messages go straight to the core; only the ones the shell may act on are parsed.
        if text.contains("\"shell.") || text.contains("\"core.exit\""),
           let request = Request(text) {
            if request.method.hasPrefix("shell.") {
                answer(request)
                return
            }
            if request.method == "core.exit", let path = Self.snapshotPath {
                Task {
                    do {
                        try await snapshot(to: path)
                    } catch {
                        NSLog("shell: the snapshot to %@ failed: %@", path, error.localizedDescription)
                    }
                    OmpcoreSend(text)
                }
                return
            }
        }
        OmpcoreSend(text)
    }

    private func answer(_ request: Request) {
        guard let id = request.id else {
            NSLog("shell: dropped a %@ request without an id", request.method)
            return
        }
        let generation = generation
        Task {
            var reply: [String: Any] = ["id": id]
            do {
                reply["result"] = try await handle(request.method, Params(values: request.params))
            } catch {
                var body: [String: Any] = ["message": error.localizedDescription]
                body["code"] = (error as? ShellError)?.code
                reply["error"] = body
            }
            deliver(Self.json(reply), from: generation)
        }
    }

    /// The file behind a URL of the page's origin (`cache/…`), for shell.saveFile.
    func file(at url: String) throws -> URL {
        guard let absolute = URL(string: url, relativeTo: Self.startURL)?.absoluteURL, let file = files.file(for: absolute),
              FileManager.default.fileExists(atPath: file.path)
        else { throw ShellError("no file at \(url)") }
        return file
    }

    /// JSON text of a value the shell built or parsed, which is always valid JSON.
    static func json(_ value: Any) -> String {
        do {
            return String(decoding: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), as: UTF8.self)
        } catch {
            fatalError("not JSON: \(error)")
        }
    }

    /// Writes a picture of the window to `path`.
    func snapshot(to path: String) async throws {
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let png = picture(of: image) else { throw ShellError("encoding the snapshot as PNG failed") }
        try png.write(to: URL(fileURLWithPath: path))
    }

    #if os(macOS)
    /// The page's snapshot with the title bar's views (the traffic lights) drawn over it: the window as the user sees
    /// it, which screencapture cannot take from an SSH session.
    private func picture(of page: NSImage) -> Data? {
        let bounds = webView.bounds
        guard let picture = webView.bitmapImageRepForCachingDisplay(in: bounds),
              let context = NSGraphicsContext(bitmapImageRep: picture)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        page.draw(in: bounds)
        // The buttons alone: drawn on its own, the title bar view paints the window's background under them.
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = webView.window?.standardWindowButton(type),
                  let image = button.bitmapImageRepForCachingDisplay(in: button.bounds)
            else { continue }
            button.cacheDisplay(in: button.bounds, to: image)
            // Window coordinates are the web view's: it fills the window.
            image.draw(in: button.convert(button.bounds, to: nil))
        }
        NSGraphicsContext.restoreGraphicsState()
        return picture.representation(using: .png, properties: [:])
    }
    #else
    private func picture(of page: UIImage) -> Data? {
        page.pngData()
    }
    #endif

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        timing.mark("commitMs")
        pageReady = false
        // A page that commits over another one (its own reload, the context menu's Reload): Start again makes the core
        // release what the old page opened, and the new generation drops what is still queued for it, whose ids the new
        // page reuses (docs/contracts/bridge.md, Core bindings). At commit the old document has stopped running.
        if !coreIsFresh { startCore() }
        coreIsFresh = false
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        timing.mark("policyMs")
        decisionHandler(policy(for: navigationAction))
    }

    /// Links open only through shell.openUrl, which the page calls after asking the user: a navigation away from the
    /// app is cancelled, never handed to the browser.
    private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        switch action.targetFrame?.isMainFrame {
        case true? where Self.isApp(url):
            return .allow
        // Subframes: the agent-HTML frame (the bundle's frame.html) and what its page embeds. The pages' policies decide
        // which of these load: the app page's frame-src 'self', frame.html's https:, data: and blob:.
        case false? where Self.isApp(url) || Self.subframeSchemes.contains(url.scheme ?? ""):
            return .allow
        default:
            NSLog("shell: blocked a navigation to %@://%@", url.scheme ?? "", url.host ?? "")
            return .cancel
        }
    }

    // window.open and target=_blank: the page never gets a second web view, and no link opens the browser this way.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        NSLog("shell: blocked a new window for %@", navigationAction.request.url?.scheme ?? "no URL")
        return nil
    }

    #if os(macOS)
    // <input type=file>: AppKit's open panel, as a sheet of the window. iOS's web view brings its own picker.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        guard let window = webView.window else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        Task {
            let response = await panel.beginSheetModal(for: window)
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
    #endif

    // A fresh page, as on a launch: the core outlives the dead page, but not what it opened.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("shell: the web content process ended; reloading the page")
        startCore()
        webView.load(URLRequest(url: Self.pageURL))
    }

    private static func isApp(_ url: URL) -> Bool {
        url.scheme == "app" && url.host == "ompanion"
    }

    /// Besides the app's own: srcdoc and blank frames, and what frame.html's policy lets an agent page embed.
    private static let subframeSchemes: Set<String> = ["about", "https", "data", "blob"]
}

/// The core's listener for one page.
private final class PageListener: NSObject, OmpcoreListenerProtocol, Sendable {
    let shell: Shell
    let generation: Int

    init(shell: Shell, generation: Int) {
        self.shell = shell
        self.generation = generation
    }

    // Called on a core thread, one message at a time; the main queue keeps their order.
    func onMessage(_ message: String?) {
        guard let message else { return }
        DispatchQueue.main.async { [shell, generation] in
            shell.deliver(message, from: generation)
        }
    }
}

/// A page request, as far as the shell reads it.
private struct Request {
    let id: Any?
    let method: String
    let params: [String: Any]

    init?(_ text: String) {
        // A message that is not a request is the core's to reject.
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let method = object["method"] as? String
        else { return nil }
        id = object["id"]
        self.method = method
        params = object["params"] as? [String: Any] ?? [:]
    }
}
