import UserNotifications
import os

/// Replaces the relay's placeholder alert with the decrypted notification (docs/contracts/push.md, Relay and
/// Receiving). A message that does not open shows the placeholder unchanged.
final class NotificationService: UNNotificationServiceExtension {
  private let log = Logger(subsystem: "com.edde746.ompanion.NotificationService", category: "push")
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var placeholder: UNNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    placeholder = request.content
    let content: UNNotificationContent
    do {
      content = try decrypted(request.content)
    } catch {
      log.error("Showing the placeholder: \(String(describing: error), privacy: .public)")
      content = request.content
    }
    deliver(content)
  }

  override func serviceExtensionTimeWillExpire() {
    if let placeholder { deliver(placeholder) }
  }

  private func deliver(_ content: UNNotificationContent) {
    contentHandler?(content)
    contentHandler = nil
  }

  private func decrypted(_ content: UNNotificationContent) throws -> UNNotificationContent {
    let userInfo = content.userInfo
    guard (userInfo["v"] as? Int) == 1, let nonce = userInfo["n"] as? String, let ciphertext = userInfo["c"] as? String
    else { throw PushOpenError("not a version 1 message") }
    guard let key = try PushKeychain.read(.key),
      let deviceId = try PushKeychain.read(.deviceId).map({ String(decoding: $0, as: UTF8.self) })
    else { throw PushOpenError("push is off") }
    let message = try openPush(nonce: nonce, ciphertext: ciphertext, key: key, deviceId: deviceId, now: Date())
    let result = content.mutableCopy() as! UNMutableNotificationContent
    result.title = message.title
    result.subtitle = message.subtitle
    result.body = message.body
    result.threadIdentifier = message.thread
    // The routing fields the app reads when the notification is shown or tapped (Runner/Push.swift).
    var routed = userInfo
    routed["machineId"] = message.machineId
    routed["runId"] = message.runId
    routed["sessionPath"] = message.sessionPath
    result.userInfo = routed
    return result
  }
}
