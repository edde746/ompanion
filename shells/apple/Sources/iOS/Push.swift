import CryptoKit
import FirebaseCore
import FirebaseInstallations
import FirebaseMessaging
import UIKit
import UserNotifications

/// The routing fields of a notification from the relay (decrypted by the extension, or still its placeholder); nil
/// for any other notification.
struct PushRoute: Sendable {
    let machineId: String?
    let runId: String?
    let sessionPath: String?

    init?(_ userInfo: [AnyHashable: Any]) {
        guard userInfo["c"] != nil else { return nil }
        machineId = userInfo["machineId"] as? String
        runId = userInfo["runId"] as? String
        sessionPath = userInfo["sessionPath"] as? String
    }
}

/// Push on iOS (docs/contracts/push.md): the shell.push* methods and the shell.pushFid and shell.pushTap events, FCM
/// registration of the Firebase installation, and the notifications the Notification Service Extension decrypted.
/// Firebase runs only while push is on, so the app does not contact Google before the user turns it on. Its state is
/// the Flutter app's (PushKeychain, the UserDefaults below), so registrations made by the Flutter app keep working.
@MainActor
final class Push: NSObject, MessagingDelegate {
    private struct VisibleSession {
        let machineId: String
        let runId: String?
        let sessionPath: String?
    }

    private struct NotConfigured: Error, CustomStringConvertible {
        let description: String
    }

    // In UserDefaults, which a reinstall clears, unlike the keychain. Push is on while an FID is stored; `started` says
    // that `enable` started Firebase in this install, so `disable` has an installation to delete.
    private static let fidDefault = "ompanion.push.fid"
    private static let startedDefault = "ompanion.push.started"

    weak var shell: Shell?
    private var firebaseStarted = false
    private var visible: VisibleSession?
    private var enabling = false
    /// `enable` waiting for the APNs token.
    private var tokenWaiter: CheckedContinuation<Void, any Error>?
    private var launchTap: [String: Any]?
    // Until the page takes the launch tap, a later tap replaces it; afterwards taps reach the page as events.
    private var launchTapTaken = false

    private var isOn: Bool { UserDefaults.standard.string(forKey: Self.fidDefault) != nil }

    /// The build has Firebase's client config (shell.info's `push`).
    static var configured: Bool { (try? firebaseOptions()) != nil }

    /// From application(_:didFinishLaunchingWithOptions:).
    func start() {
        guard isOn, let options = try? Self.firebaseOptions() else { return }
        startFirebase(options)
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - APNs

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard firebaseStarted else { return }
        Messaging.messaging().apnsToken = deviceToken
        tokenWaiter?.resume()
        tokenWaiter = nil
    }

    func didFailToRegisterForRemoteNotifications(_ error: any Error) {
        tokenWaiter?.resume(throwing: error)
        tokenWaiter = nil
    }

    // MARK: - Notifications

    func presentation(for route: PushRoute) -> UNNotificationPresentationOptions {
        shows(route) ? [] : [.banner, .list, .sound]
    }

    func tapped(_ route: PushRoute) {
        // The placeholder of a message the extension could not open leads nowhere but the app.
        guard let machineId = route.machineId else { return }
        let tap: [String: Any] = [
            "machineId": machineId,
            "runId": route.runId ?? NSNull(),
            "sessionPath": route.sessionPath ?? NSNull(),
        ]
        if launchTapTaken {
            shell?.emit("shell.pushTap", tap)
        } else {
            launchTap = tap
        }
    }

    // MARK: - MessagingDelegate

    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistration installationId: String?) {
        guard let installationId else { return }
        Task { @MainActor in
            // Push is off, or `enable` has not stored its FID yet and reports it itself.
            guard self.isOn, UserDefaults.standard.string(forKey: Self.fidDefault) != installationId else { return }
            UserDefaults.standard.set(installationId, forKey: Self.fidDefault)
            self.shell?.emit("shell.pushFid", ["fid": installationId])
        }
    }

    // MARK: - Shell methods

    func handle(_ method: String, _ params: Params) async throws -> Any {
        switch method {
        case "shell.pushStatus":
            do {
                _ = try Self.firebaseOptions()
                return ["available": true, "reason": NSNull()]
            } catch {
                return ["available": false, "reason": String(describing: error)]
            }
        case "shell.pushEnable":
            return try await enable(deviceId: params.string("deviceId"))
        case "shell.pushRegistration":
            return try registration() ?? NSNull()
        case "shell.pushDisable":
            try await disable()
            return [:]
        case "shell.pushSetVisible":
            visible = try params.optionalString("machineId").map {
                VisibleSession(
                    machineId: $0, runId: try params.optionalString("runId"),
                    sessionPath: try params.optionalString("sessionPath"))
            }
            return [:]
        case "shell.pushClear":
            await clear(thread: try params.optionalString("runId") ?? params.string("machineId"))
            return [:]
        case "shell.pushTakeLaunchTap":
            launchTapTaken = true
            defer { launchTap = nil }
            return launchTap ?? NSNull()
        default:
            throw ShellError.unknownMethod(method)
        }
    }

    /// Asks for permission, makes the key, registers the installation with FCM once APNs gave a token, and returns the
    /// registration. Errors carry the code `unavailable`, `denied` or `failed`.
    private func enable(deviceId: String) async throws -> [String: String] {
        let options: FirebaseOptions
        do {
            options = try Self.firebaseOptions()
        } catch {
            throw ShellError(String(describing: error), code: "unavailable")
        }
        guard !enabling else { throw ShellError("push is already being turned on", code: "failed") }
        enabling = true
        defer { enabling = false }
        let granted: Bool
        do {
            granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            throw Self.failed(error)
        }
        guard granted else { throw ShellError("notifications are off for ompanion", code: "denied") }
        do {
            if try PushKeychain.read(.key) == nil {
                try PushKeychain.write(.key, SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
            }
            try PushKeychain.write(.deviceId, Data(deviceId.utf8))
            UserDefaults.standard.set(true, forKey: Self.startedDefault)
            startFirebase(options)
            try await withCheckedThrowingContinuation { continuation in
                tokenWaiter = continuation
                UIApplication.shared.registerForRemoteNotifications()
            }
            // FCM registers the installation for APNs delivery only once it has the APNs token.
            try await Messaging.messaging().register()
            let fid = try await Installations.installations().installationID()
            UserDefaults.standard.set(fid, forKey: Self.fidDefault)
            // From now on FCM keeps the registration fresh on every launch; it stays off while push is off.
            Messaging.messaging().isAutoInitEnabled = true
            guard let registration = try registration() else { throw ShellError("the push key is gone", code: "failed") }
            return registration
        } catch let error as ShellError {
            throw error
        } catch {
            throw Self.failed(error)
        }
    }

    /// What `enable` and `registration` return, or nil while push is off.
    private func registration() throws -> [String: String]? {
        guard let fid = UserDefaults.standard.string(forKey: Self.fidDefault), let key = try PushKeychain.read(.key) else {
            return nil
        }
        return ["platform": "ios", "fid": fid, "key": key.base64EncodedString()]
    }

    // Unregisters from FCM and deletes the Firebase installation, then forgets the key, so Firebase is not started on
    // the next launch. A failure leaves push on, so turning it off can be retried: auto-init goes back to what it was,
    // because the SDK persists it and push left on without it would stop refreshing its registration.
    private func disable() async throws {
        if UserDefaults.standard.bool(forKey: Self.startedDefault), let options = try? Self.firebaseOptions() {
            startFirebase(options)
            let messaging = Messaging.messaging()
            let autoInit = messaging.isAutoInitEnabled
            messaging.isAutoInitEnabled = false
            do {
                try await messaging.unregister()
                try await Installations.installations().delete()
            } catch {
                messaging.isAutoInitEnabled = autoInit
                throw Self.failed(error)
            }
        }
        do {
            try PushKeychain.delete(.key)
            try PushKeychain.delete(.deviceId)
        } catch {
            throw Self.failed(error)
        }
        UserDefaults.standard.removeObject(forKey: Self.fidDefault)
        UserDefaults.standard.removeObject(forKey: Self.startedDefault)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    private func startFirebase(_ options: FirebaseOptions) {
        guard !firebaseStarted else { return }
        FirebaseApp.configure(options: options)
        Messaging.messaging().delegate = self
        firebaseStarted = true
    }

    private func shows(_ route: PushRoute) -> Bool {
        guard let visible, route.machineId == visible.machineId else { return false }
        return (route.runId != nil && route.runId == visible.runId)
            || (route.sessionPath != nil && route.sessionPath == visible.sessionPath)
    }

    private func clear(thread: String) async {
        let center = UNUserNotificationCenter.current()
        let session = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == thread }
        center.removeDeliveredNotifications(withIdentifiers: session.map(\.request.identifier))
    }

    /// Firebase's client config from Info.plist (Firebase.xcconfig).
    private static func firebaseOptions() throws -> FirebaseOptions {
        let info = Bundle.main.infoDictionary ?? [:]
        let settings = [
            "FIREBASE_GOOGLE_APP_ID": "OmpanionFirebaseAppID",
            "FIREBASE_GCM_SENDER_ID": "OmpanionFirebaseSenderID",
            "FIREBASE_API_KEY": "OmpanionFirebaseAPIKey",
            "FIREBASE_PROJECT_ID": "OmpanionFirebaseProjectID",
        ].mapValues { info[$0] as? String ?? "" }
        let missing = settings.filter { $0.value.isEmpty }.keys.sorted()
        if missing.count == settings.count { throw NotConfigured(description: "not configured") }
        guard missing.isEmpty else {
            throw NotConfigured(description: "shells/apple/Firebase.xcconfig has no \(missing.joined(separator: ", "))")
        }
        let options = FirebaseOptions(
            googleAppID: settings["FIREBASE_GOOGLE_APP_ID"]!,
            gcmSenderID: settings["FIREBASE_GCM_SENDER_ID"]!
        )
        options.apiKey = settings["FIREBASE_API_KEY"]
        options.projectID = settings["FIREBASE_PROJECT_ID"]
        return options
    }

    private static func failed(_ error: any Error) -> ShellError {
        ShellError(String(describing: error), code: "failed")
    }
}
