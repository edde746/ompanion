import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  #if !DEBUG
    /// Checks the GitHub release feed (`SUFeedURL`) on Sparkle's schedule and from "Check for Updates…". Not in debug
    /// builds, which would otherwise offer to replace themselves with the latest release.
    private let updaterController = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  #endif

  // FlutterAppDelegate declares this through NSApplicationDelegate but does not implement it: no super call.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    #if !DEBUG
      // Right after About, where Mac apps put it. The controller enables the item only while a check can start.
      let item = NSMenuItem(
        title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
        keyEquivalent: "")
      item.target = updaterController
      let menu = applicationMenu!
      let about = menu.indexOfItem(
        withTarget: nil, andAction: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
      menu.insertItem(item, at: about + 1)
    #endif
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
