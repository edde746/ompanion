import AppKit
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Made before AppKit finishes launching: the page loads while it does, and the notification center's delegate is
    /// set before launch ends, as it must be to hear of the tap that launched the app.
    private let shell = Shell()
    private var window: MainWindow?
    #if !DEBUG
    /// Checks the GitHub release feed (`SUFeedURL`) on Sparkle's schedule and from "Check for Updates…". Not in debug
    /// builds, which would otherwise offer to replace themselves with the latest release.
    private var updater: SPUStandardUpdaterController?
    #endif

    func probe(_ main: Date, _ app: Date) {
        shell.timing.mark("mainMs", at: main)
        shell.timing.mark("nsAppMs", at: app)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        shell.timing.mark("willFinishLaunchingMs")
        window = MainWindow(shell: shell)
        shell.timing.mark("windowMs")
        #if !DEBUG
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
        NSApp.mainMenu = mainMenu()
        shell.timing.mark("menuMs")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        shell.timing.mark("didFinishLaunchingMs")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        shell.timing.mark("shownMs")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The standard Mac menus (app, Edit, View, Window) without Edit's submenus (Find, Spelling, Substitutions,
    /// Transformations, Speech) and Help, and in release builds Sparkle's "Check for Updates…" after About. Without an
    /// Edit menu the web view gets no copy, paste or select-all shortcuts.
    private func mainMenu() -> NSMenu {
        let app = NSMenu()
        app.addItem(withTitle: "About ompanion", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        #if !DEBUG
        // The controller enables the item only while a check can start.
        app.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            .target = updater
        #endif
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide ompanion", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit ompanion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let menu = NSMenu()
        for submenu in [app, edit, view, window] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return menu
    }
}

let mainStart = Date()
let app = NSApplication.shared
let appCreated = Date()
let delegate = AppDelegate()
delegate.probe(mainStart, appCreated)
app.delegate = delegate
app.run()
