import WebKit

/// The page's web view, which takes drags of files and folders itself (docs/contracts/bridge.md, Desktop file paths):
/// the page hears `shell.drag {active}` while they are over the window and `shell.drop {paths}` when they are dropped,
/// with the paths where they are. Every other drag (text, the page's own) goes to WebKit.
final class FileDropWebView: WKWebView {
    weak var shell: Shell?
    /// Whether the drag over the window carries files.
    private var draggingFiles = false

    private static func paths(_ info: any NSDraggingInfo) -> [String]? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        guard let urls = urls as? [URL], !urls.isEmpty else { return nil }
        return urls.map(\.path)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard Self.paths(sender) != nil else { return super.draggingEntered(sender) }
        draggingFiles = true
        shell?.emit("shell.drag", ["active": true])
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingFiles ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard draggingFiles else { return super.draggingExited(sender) }
        draggingFiles = false
        shell?.emit("shell.drag", ["active": false])
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingFiles || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard draggingFiles else { return super.performDragOperation(sender) }
        draggingFiles = false
        shell?.emit("shell.drag", ["active": false])
        guard let paths = Self.paths(sender) else { return false }
        shell?.emit("shell.drop", ["paths": paths])
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        // A file drop ended in performDragOperation; WebKit concludes only its own.
        if let sender, Self.paths(sender) != nil { return }
        super.concludeDragOperation(sender)
    }
}
