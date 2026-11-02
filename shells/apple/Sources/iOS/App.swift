import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Made with the app, not with its scene: the page starts loading at once, and the notification center's delegate
    /// is set before launch ends, as it must be to hear of the tap that launched the app.
    let shell = Shell()

    override init() {
        super.init()
        shell.timing.mark("mainMs", at: mainStart)
        // The web view declines Paste while the pasteboard holds no text, so iOS asks on up the responder chain to
        // here (ImagePaste.swift).
        pasteConfiguration = ImagePaste.configuration
    }

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        shell.push.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        shell.push.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        shell.push.didFailToRegisterForRemoteNotifications(error)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        Task {
            let files = await ImagePaste.files(itemProviders, cache: Shell.appFolder(.cachesDirectory))
            if !files.isEmpty { shell.emit("shell.pasteFiles", ["files": files]) }
        }
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene, let app = UIApplication.shared.delegate as? AppDelegate else { return }
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = Shell.background
        window.rootViewController = WebViewController(shell: app.shell)
        window.makeKeyAndVisible()
        app.shell.timing.mark("shownMs")
        self.window = window
    }
}

/// The web view fills the screen; the page keeps its content clear of the notch, the home indicator and the keyboard
/// with shell.insets (docs/design.md rule 13).
final class WebViewController: UIViewController, ShellHost {
    private let shell: Shell

    /// The docked keyboard's height over the view, in points (CSS px); 0 while it is hidden or floats.
    private var keyboard: CGFloat = 0

    /// The insets the last shell.insets event carried.
    private var sentInsets: [String: Double] = [:]

    init(shell: Shell) {
        self.shell = shell
        super.init(nibName: nil, bundle: nil)
        shell.host = self
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(keyboardWillChangeFrame), name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        // The page keeps clear of the keyboard itself (shell.insets). Left to hear of the keyboard, WebKit would also
        // inset its scroll view and scroll the focused field into view, panning the whole page, header and all, up over
        // the room the page made.
        for name in [
            UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillHideNotification, UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification,
        ] {
            center.removeObserver(shell.webView, name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WebViewController is made in code")
    }

    override func loadView() {
        view = shell.webView
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        insetsChanged()
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let screen = view.window?.screen
        else { return }
        let overlap = view.bounds.intersection(view.convert(frame, from: screen.coordinateSpace))
        keyboard = overlap.isNull ? 0 : view.bounds.maxY - overlap.minY
        insetsChanged()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboard = 0
        insetsChanged()
    }

    private var insets: [String: Double] {
        let safe = view.safeAreaInsets
        return ["top": safe.top, "right": safe.right, "bottom": safe.bottom, "left": safe.left, "keyboard": keyboard]
    }

    private func insetsChanged() {
        let insets = insets
        guard insets != sentInsets else { return }
        sentInsets = insets
        shell.emit("shell.insets", insets)
    }

    func answer(_ method: String, _ params: Params) throws -> [String: Any] {
        switch method {
        case "shell.insets":
            return insets
        default:
            throw ShellError.unknownMethod(method)
        }
    }

    /// The share sheet with a copy of `file` named `name` ("Save to Files" is one of its actions); true when the user
    /// completed an action.
    func save(_ file: URL, as name: String) async throws -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                NSLog("shell: removing %@ failed: %@", folder.path, error.localizedDescription)
            }
        }
        let copy = folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        let sheet = UIActivityViewController(activityItems: [copy], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        var top: UIViewController = self
        while let presented = top.presentedViewController {
            top = presented
        }
        return await withCheckedContinuation { continuation in
            // The handler can run again after a sub-sheet (Save to Files) is dismissed; the first call answers.
            var pending: CheckedContinuation<Bool, Never>? = continuation
            sheet.completionWithItemsHandler = { _, completed, _, _ in
                pending?.resume(returning: completed)
                pending = nil
            }
            top.present(sheet, animated: true)
        }
    }
}
