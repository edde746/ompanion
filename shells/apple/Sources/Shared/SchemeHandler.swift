import UniformTypeIdentifiers
import WebKit

/// Serves app://ompanion/<path>: the bundle's `ui` folder, and under `cache/` the core's cache folder
/// (docs/contracts/bridge.md, Cache files). It honours a byte range, which media elements ask for, and sends a file in
/// chunks with the run loop turning between them, so a large video never sits in memory whole.
@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private static let chunkSize = 1 << 20

    private let root: URL
    private let cache: URL
    /// Responses still sending their body, by task.
    private var transfers: [ObjectIdentifier: Transfer] = [:]

    private struct Transfer {
        let task: any WKURLSchemeTask
        let handle: FileHandle
        var remaining: Int
    }

    init(root: URL, cache: URL) {
        self.root = root.standardizedFileURL
        self.cache = cache.standardizedFileURL
    }

    /// The file an app://ompanion/ URL names; nil outside the two folders.
    func file(for url: URL) -> URL? {
        guard url.scheme == "app", url.host == "ompanion" else { return nil }
        let path = url.path
        let (folder, relative) = path.hasPrefix("/cache/") ? (cache, String(path.dropFirst("/cache".count))) : (root, path)
        let file = folder.appendingPathComponent(relative).standardizedFileURL
        return file.path.hasPrefix(folder.path + "/") ? file : nil
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        var isDirectory: ObjCBool = false
        guard let file = file(for: url), FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            let body = Data("not found\n".utf8)
            let headers = ["Content-Type": "text/plain; charset=utf-8", "Content-Length": String(body.count)]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(body)
            task.didFinish()
            return
        }
        let handle: FileHandle
        let size: Int
        do {
            handle = try FileHandle(forReadingFrom: file)
            size = Int(try handle.seekToEnd())
        } catch {
            NSLog("shell: opening %@ failed: %@", file.path, error.localizedDescription)
            task.didFailWithError(error)
            return
        }
        var headers = ["Content-Type": Self.contentType(file.pathExtension), "Accept-Ranges": "bytes", "Cache-Control": "no-cache"]
        if file.path.hasPrefix(cache.path + "/") {
            // Files from machines and the web: one loaded as a document never runs as the app (images are unaffected).
            headers["Content-Security-Policy"] = "sandbox"
            headers["X-Content-Type-Options"] = "nosniff"
        }
        var status = 200
        var range = 0..<size
        if let requested = Self.range(task.request.value(forHTTPHeaderField: "Range"), size: size) {
            if requested.isEmpty {
                headers["Content-Range"] = "bytes */\(size)"
                headers["Content-Length"] = "0"
                task.didReceive(HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: headers)!)
                task.didFinish()
                return
            }
            status = 206
            range = requested
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)"
        }
        headers["Content-Length"] = String(range.count)
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
        } catch {
            NSLog("shell: seeking in %@ failed: %@", file.path, error.localizedDescription)
            task.didFailWithError(error)
            return
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        let id = ObjectIdentifier(task)
        transfers[id] = Transfer(task: task, handle: handle, remaining: range.count)
        send(id)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        // Dropping the transfer closes its file; a chunk already queued finds it gone.
        transfers[ObjectIdentifier(task)] = nil
    }

    /// Sends a transfer's next chunk, then lets the run loop turn (other requests, `stop`) before the one after.
    private func send(_ id: ObjectIdentifier) {
        guard var transfer = transfers[id] else { return }
        if transfer.remaining > 0 {
            let chunk: Data
            do {
                chunk = try transfer.handle.read(upToCount: min(Self.chunkSize, transfer.remaining)) ?? Data()
            } catch {
                transfers[id] = nil
                transfer.task.didFailWithError(error)
                return
            }
            guard !chunk.isEmpty else {
                transfers[id] = nil
                transfer.task.didFailWithError(URLError(.cannotDecodeContentData))
                return
            }
            transfer.task.didReceive(chunk)
            transfer.remaining -= chunk.count
        }
        guard transfer.remaining > 0 else {
            transfers[id] = nil
            transfer.task.didFinish()
            return
        }
        transfers[id] = transfer
        DispatchQueue.main.async { self.send(id) }
    }

    /// The bytes a `Range: bytes=…` header asks for, clamped to the file: nil without a header this handler reads (the
    /// whole file), empty when none of them exist. Of several ranges only the first is served.
    private static func range(_ header: String?, size: Int) -> Range<Int>? {
        guard let header, header.hasPrefix("bytes="),
              let spec = header.dropFirst("bytes=".count).split(separator: ",").first
        else { return nil }
        let bounds = spec.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        switch (Int(bounds[0]), Int(bounds[1])) {
        case let (first?, last?) where first <= last:
            return first < size ? first..<min(last + 1, size) : size..<size
        case let (first?, nil) where bounds[1].isEmpty:
            return first < size ? first..<size : size..<size
        case let (nil, count?) where bounds[0].isEmpty:
            return count > 0 ? max(0, size - count)..<size : size..<size
        default:
            return nil
        }
    }

    private static func contentType(_ fileExtension: String) -> String {
        let type: String
        // The page's own files, whose types WebKit checks strictly (module scripts, fonts, wasm); the system's table
        // for the rest (images, media, documents in the cache).
        switch fileExtension.lowercased() {
        case "html", "htm": type = "text/html"
        case "js", "mjs": type = "text/javascript"
        case "css": type = "text/css"
        case "json", "map": type = "application/json"
        case "svg": type = "image/svg+xml"
        case "woff": type = "font/woff"
        case "woff2": type = "font/woff2"
        case "ttf": type = "font/ttf"
        case "otf": type = "font/otf"
        case "wasm": type = "application/wasm"
        default: type = UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        let text = type.hasPrefix("text/") || type == "application/json" || type == "image/svg+xml"
        return text ? type + "; charset=utf-8" : type
    }
}
