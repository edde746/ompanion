import Foundation
import Security
import UserNotifications

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a shell.* request answers with when it fails: `{message, code?}` (docs/contracts/bridge.md, Error codes).
struct ShellError: LocalizedError {
    let message: String
    let code: String?

    init(_ message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }

    var errorDescription: String? { message }

    static func unknownMethod(_ method: String) -> ShellError {
        ShellError("unknown method \"\(method)\"")
    }
}

/// A shell request's params, checked where they are read.
struct Params {
    let values: [String: Any]

    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String else { throw ShellError("\(key) must be a string") }
        return value
    }

    /// nil when absent or null.
    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw ShellError("\(key) must be a string") }
        return string
    }

    func number(_ key: String) throws -> Double {
        guard let value = values[key] as? Double else { throw ShellError("\(key) must be a number") }
        return value
    }

    /// false when absent or null.
    func bool(_ key: String) throws -> Bool {
        guard let value = values[key], !(value is NSNull) else { return false }
        guard let bool = value as? Bool else { throw ShellError("\(key) must be a boolean") }
        return bool
    }

    /// `[{x, y, width, height}]`.
    func rects(_ key: String) throws -> [CGRect] {
        guard let list = values[key] as? [[String: Any]] else { throw ShellError("\(key) must be a list of rects") }
        return try list.map { values in
            let rect = Params(values: values)
            return CGRect(
                x: try rect.number("x"), y: try rect.number("y"),
                width: try rect.number("width"), height: try rect.number("height"))
        }
    }
}

extension Shell {
    /// Answers one shell.* request (docs/contracts/bridge.md, Shell services) with its result, NSNull for null; the
    /// window's own go to the host.
    func handle(_ method: String, _ params: Params) async throws -> Any {
        switch method {
        case "shell.info":
            return try Self.info()
        case "shell.secretGet":
            let value = try Keychain.app.get(params.string("key"))
            return ["value": value as Any? ?? NSNull()]
        case "shell.secretSet":
            try Keychain.app.set(params.string("key"), params.string("value"))
            return [:]
        case "shell.secretDelete":
            try Keychain.app.delete(params.string("key"))
            return [:]
        case "shell.flutterData":
            return try FlutterData.read()
        case "shell.flutterDataClear":
            try FlutterData.clear()
            return [:]
        case "shell.openUrl":
            let text = try params.string("url")
            guard let url = URL(string: text), url.scheme != nil else { throw ShellError("not a URL: \(text)") }
            #if os(macOS)
            let opened = NSWorkspace.shared.open(url)
            #else
            let opened = await UIApplication.shared.open(url)
            #endif
            guard opened else { throw ShellError("no app opens \(text)") }
            return [:]
        case "shell.clipboardWrite":
            let text = try params.string("text")
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
            return [:]
        case "shell.notify":
            try await Self.notify(params, atMs: nil)
            return [:]
        case "shell.notifySchedule":
            try await Self.notify(params, atMs: params.number("atMs"))
            return [:]
        case "shell.notifyCancel":
            let id = try params.string("id")
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
            return [:]
        case "shell.notifyPermission":
            return ["granted": try await Self.notificationPermission(request: params.bool("request"))]
        case "shell.saveFile":
            let file = try file(at: params.string("url"))
            return ["saved": try await window().save(file, as: params.string("name"))]
        case "shell.timing":
            try timing.write(page: params.values)
            return [:]
        case "shell.snapshot" where Self.snapshotPath != nil:
            try await snapshot(to: params.string("path"))
            return [:]
        #if os(iOS)
        case _ where method.hasPrefix("shell.push"):
            return try await push.handle(method, params)
        #endif
        default:
            return try await window().answer(method, params)
        }
    }

    private func window() throws -> ShellHost {
        guard let host else { throw ShellError("the app has no window yet") }
        return host
    }

    private static func info() throws -> [String: Any] {
        #if os(macOS)
        let platform = "macos"
        let push = false
        #else
        let platform = "ios"
        let push = Push.configured
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // The host name (gethostname): the app names this device and key comments with it.
        var host = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&host, host.count) == 0 else {
            throw ShellError("gethostname failed: \(String(cString: strerror(errno)))")
        }
        return [
            "platform": platform,
            "osVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "device": host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) },
            "push": push,
            // macOS answers shell.pickFiles and shell.clipboardFiles and sends shell.drag and shell.drop (MainWindow).
            "paths": platform == "macos",
        ]
    }

    /// Posts a notification now, or at `atMs` (epoch ms) when that is still ahead.
    private static func notify(_ params: Params, atMs: Double?) async throws {
        let content = UNMutableNotificationContent()
        content.title = try params.string("title")
        content.subtitle = try params.optionalString("subtitle") ?? ""
        content.body = try params.string("body")
        content.threadIdentifier = try params.optionalString("threadId") ?? ""
        content.sound = .default
        if let data = params.values["data"] {
            // As JSON text: user info holds property-list values only, and JSON's null is none of them.
            content.userInfo = ["data": json(data)]
        }
        var trigger: UNNotificationTrigger?
        if let atMs, atMs > Date().timeIntervalSince1970 * 1000 {
            let date = Date(timeIntervalSince1970: atMs / 1000)
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }
        let request = UNNotificationRequest(identifier: try params.string("id"), content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }

    private static func notificationPermission(request: Bool) async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        if request {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// A tap on one of the app's notifications.
    func notificationTapped(id: String, data: String?) {
        var value: Any = NSNull()
        if let data {
            do {
                value = try JSONSerialization.jsonObject(with: Data(data.utf8), options: .fragmentsAllowed)
            } catch {
                NSLog("shell: notification %@ carries data that is not JSON: %@", id, error.localizedDescription)
            }
        }
        sendTap(Self.json(["event": "shell.notificationTap", "params": ["id": id, "data": value]]))
        #if os(macOS)
        // iOS brings the app forward on a tap itself.
        if let window = webView.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }
}

extension Shell: UNUserNotificationCenterDelegate {
    // A notification the page posts shows while the app is in front too: the page decides when to post one. A push
    // notification shows unless its session is on screen (Push.swift).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        #if os(iOS)
        if let route = PushRoute(notification.request.content.userInfo) {
            return await push.presentation(for: route)
        }
        #endif
        return [.banner, .list, .sound]
    }

    // The completion-handler form, called back on the main thread: UIKit updates the app's snapshot in the handler and
    // aborts when that is off the main thread, which is where the async form's handler runs (a cold launch from a tap
    // crashed in it).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return completionHandler() }
        let request = response.notification.request
        let id = request.identifier
        let data = request.content.userInfo["data"] as? String
        #if os(iOS)
        let route = PushRoute(request.content.userInfo)
        #endif
        Task { @MainActor in
            #if os(iOS)
            if let route {
                push.tapped(route)
                return completionHandler()
            }
            #endif
            notificationTapped(id: id, data: data)
            completionHandler()
        }
    }
}

/// Secrets as Keychain generic passwords of one service, one per key. macOS keeps them in the login keychain, as the
/// Flutter app did (flutter_secure_storage's `usesDataProtectionKeychain: false`): the data protection keychain needs
/// a provisioning profile. iOS keeps them in the app's first keychain group (Entitlements/iOS.entitlements).
struct Keychain {
    /// The app's secrets (shell.secret*).
    static let app = Keychain(service: Shell.appID)
    /// The Flutter app's flutter_secure_storage entries (FlutterData).
    static let flutter = Keychain(service: "flutter_secure_storage_service")

    let service: String

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func get(_ key: String) throws -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        guard let data = item as? Data else { throw ShellError("the keychain item \(key) holds no data") }
        return String(decoding: data, as: UTF8.self)
    }

    func set(_ key: String, _ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return try Self.check(status) }
        var item = query(key)
        item[kSecValueData as String] = data
        try Self.check(SecItemAdd(item as CFDictionary, nil))
    }

    func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecItemNotFound else { return try Self.check(status) }
    }

    /// Every key the service holds. Values are read one by one: the macOS login keychain returns no data for a query
    /// that matches more than one item.
    func keys() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        try Self.check(status)
        guard let attributes = items as? [[String: Any]] else { throw ShellError("the keychain listed no attributes") }
        return attributes.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error"
        throw ShellError("keychain: \(text) (\(status))")
    }
}
