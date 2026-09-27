import CryptoKit
import FirebaseCore
import FirebaseInstallations
import FirebaseMessaging
import Flutter
import UIKit
import UserNotifications

/// Push on iOS (docs/contracts/push.md): the `ompanion/push` channel, FCM registration of the Firebase installation,
/// and the notifications the Notification Service Extension decrypted. Firebase runs only while push is on, so the app
/// does not contact Google before the user turns it on.
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

  private var channel: FlutterMethodChannel?
  private var firebaseStarted = false
  private var visible: VisibleSession?
  private var pendingEnable: FlutterResult?
  private var launchTap: [String: Any]?
  // Until Dart takes the launch tap, a later tap replaces it; afterwards taps reach Dart as `tap` events.
  private var launchTapTaken = false

  private var isOn: Bool { UserDefaults.standard.string(forKey: Self.fidDefault) != nil }

  /// From application(_:didFinishLaunchingWithOptions:).
  func start() {
    guard isOn, let options = try? Self.firebaseOptions() else { return }
    startFirebase(options)
    UIApplication.shared.registerForRemoteNotifications()
  }

  func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ompanion/push", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    self.channel = channel
  }

  // MARK: - APNs

  func didRegisterForRemoteNotifications(deviceToken: Data) {
    guard firebaseStarted else { return }
    Messaging.messaging().apnsToken = deviceToken
    // FCM registers the installation for APNs delivery only once it has the APNs token.
    if pendingEnable != nil { register() }
  }

  func didFailToRegisterForRemoteNotifications(_ error: Error) {
    if pendingEnable != nil { finishEnable(Self.failed(error)) }
  }

  // MARK: - Notifications

  /// A notification from the relay, decrypted by the extension or still the placeholder.
  static func isOurs(_ notification: UNNotification) -> Bool {
    notification.request.content.userInfo["c"] != nil
  }

  func presentation(for notification: UNNotification) -> UNNotificationPresentationOptions {
    shows(notification.request.content.userInfo) ? [] : [.banner, .list, .sound]
  }

  func tapped(_ notification: UNNotification) {
    let userInfo = notification.request.content.userInfo
    // The placeholder of a message the extension could not open leads nowhere but the app.
    guard let machineId = userInfo["machineId"] as? String else { return }
    let tap: [String: Any] = [
      "machineId": machineId,
      "runId": userInfo["runId"] as? String ?? NSNull(),
      "sessionPath": userInfo["sessionPath"] as? String ?? NSNull(),
    ]
    if launchTapTaken { channel?.invokeMethod("tap", arguments: tap) } else { launchTap = tap }
  }

  // MARK: - MessagingDelegate

  func messaging(_ messaging: Messaging, didReceiveRegistration installationId: String?) {
    DispatchQueue.main.async {
      // Push is off, or `enable` has not stored its FID yet and reports it itself.
      guard let installationId, self.isOn, UserDefaults.standard.string(forKey: Self.fidDefault) != installationId
      else { return }
      UserDefaults.standard.set(installationId, forKey: Self.fidDefault)
      self.channel?.invokeMethod("fid", arguments: ["fid": installationId])
    }
  }

  // MARK: - Channel

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "status":
      do {
        _ = try Self.firebaseOptions()
        result(["available": true, "reason": NSNull()])
      } catch {
        result(["available": false, "reason": String(describing: error)])
      }
    case "enable":
      guard let deviceId = args?["deviceId"] as? String else { return result(Self.badArguments("enable", "deviceId")) }
      enable(deviceId: deviceId, result: result)
    case "registration":
      do { result(try registration()) } catch { result(Self.failed(error)) }
    case "disable":
      disable(result: result)
    case "setVisible":
      if let args {
        guard let machineId = args["machineId"] as? String else {
          return result(Self.badArguments("setVisible", "machineId"))
        }
        visible = VisibleSession(
          machineId: machineId,
          runId: args["runId"] as? String,
          sessionPath: args["sessionPath"] as? String
        )
      } else {
        visible = nil
      }
      result(nil)
    case "clear":
      guard let machineId = args?["machineId"] as? String else {
        return result(Self.badArguments("clear", "machineId"))
      }
      clear(thread: args?["runId"] as? String ?? machineId)
      result(nil)
    case "takeLaunchTap":
      launchTapTaken = true
      result(launchTap)
      launchTap = nil
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func enable(deviceId: String, result: @escaping FlutterResult) {
    let options: FirebaseOptions
    do {
      options = try Self.firebaseOptions()
    } catch {
      return result(FlutterError(code: "unavailable", message: String(describing: error), details: nil))
    }
    guard pendingEnable == nil else {
      return result(FlutterError(code: "failed", message: "push is already being turned on", details: nil))
    }
    pendingEnable = result
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
      DispatchQueue.main.async {
        if let error { return self.finishEnable(Self.failed(error)) }
        guard granted else {
          return self.finishEnable(
            FlutterError(code: "denied", message: "notifications are off for ompanion", details: nil)
          )
        }
        do {
          if try PushKeychain.read(.key) == nil {
            try PushKeychain.write(.key, SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
          }
          try PushKeychain.write(.deviceId, Data(deviceId.utf8))
        } catch {
          return self.finishEnable(Self.failed(error))
        }
        UserDefaults.standard.set(true, forKey: Self.startedDefault)
        self.startFirebase(options)
        // Continues in didRegisterForRemoteNotifications.
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  private func register() {
    Messaging.messaging().register { error in
      if let error { return DispatchQueue.main.async { self.finishEnable(Self.failed(error)) } }
      Installations.installations().installationID { fid, error in
        DispatchQueue.main.async {
          guard let fid else {
            return self.finishEnable(
              error.map(Self.failed) ?? FlutterError(code: "failed", message: "no installation ID", details: nil)
            )
          }
          UserDefaults.standard.set(fid, forKey: Self.fidDefault)
          // From now on FCM keeps the registration fresh on every launch; it stays off while push is off.
          Messaging.messaging().isAutoInitEnabled = true
          do { self.finishEnable(try self.registration()) } catch { self.finishEnable(Self.failed(error)) }
        }
      }
    }
  }

  private func finishEnable(_ value: Any?) {
    let result = pendingEnable
    pendingEnable = nil
    result?(value)
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
  private func disable(result: @escaping FlutterResult) {
    guard UserDefaults.standard.bool(forKey: Self.startedDefault), let options = try? Self.firebaseOptions() else {
      return forget(result)
    }
    startFirebase(options)
    let messaging = Messaging.messaging()
    let autoInit = messaging.isAutoInitEnabled
    messaging.isAutoInitEnabled = false
    let fail = { (error: Error) in
      DispatchQueue.main.async {
        messaging.isAutoInitEnabled = autoInit
        result(Self.failed(error))
      }
    }
    messaging.unregister { error in
      if let error { return fail(error) }
      Installations.installations().delete { error in
        if let error { return fail(error) }
        DispatchQueue.main.async { self.forget(result) }
      }
    }
  }

  private func forget(_ result: FlutterResult) {
    do {
      try PushKeychain.delete(.key)
      try PushKeychain.delete(.deviceId)
    } catch {
      return result(Self.failed(error))
    }
    UserDefaults.standard.removeObject(forKey: Self.fidDefault)
    UserDefaults.standard.removeObject(forKey: Self.startedDefault)
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    result(nil)
  }

  private func startFirebase(_ options: FirebaseOptions) {
    guard !firebaseStarted else { return }
    FirebaseApp.configure(options: options)
    Messaging.messaging().delegate = self
    firebaseStarted = true
  }

  private func shows(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard let visible, userInfo["machineId"] as? String == visible.machineId else { return false }
    let runId = userInfo["runId"] as? String
    let sessionPath = userInfo["sessionPath"] as? String
    return (runId != nil && runId == visible.runId) || (sessionPath != nil && sessionPath == visible.sessionPath)
  }

  private func clear(thread: String) {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { notifications in
      let session = notifications.filter { $0.request.content.threadIdentifier == thread }
      center.removeDeliveredNotifications(withIdentifiers: session.map(\.request.identifier))
    }
  }

  /// Firebase's client config from Info.plist (ios/Flutter/Firebase.xcconfig).
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
      throw NotConfigured(description: "ios/Flutter/Firebase.xcconfig has no \(missing.joined(separator: ", "))")
    }
    let options = FirebaseOptions(
      googleAppID: settings["FIREBASE_GOOGLE_APP_ID"]!,
      gcmSenderID: settings["FIREBASE_GCM_SENDER_ID"]!
    )
    options.apiKey = settings["FIREBASE_API_KEY"]
    options.projectID = settings["FIREBASE_PROJECT_ID"]
    return options
  }

  private static func failed(_ error: Error) -> FlutterError {
    FlutterError(code: "failed", message: String(describing: error), details: nil)
  }

  private static func badArguments(_ method: String, _ name: String) -> FlutterError {
    FlutterError(code: "failed", message: "\(method) needs a \(name)", details: nil)
  }
}
