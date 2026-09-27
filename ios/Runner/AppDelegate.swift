import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let push = Push()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before launch finishes, so the tap on a notification that launched the app reaches userNotificationCenter.
    UNUserNotificationCenter.current().delegate = self
    push.start()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    push.attach(engineBridge.applicationRegistrar.messenger())
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    push.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    push.didFailToRegisterForRemoteNotifications(error)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  // FlutterAppDelegate hands the notifications that are not push's to the plugins, which may have posted them.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard Push.isOurs(notification) else {
      return super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
    completionHandler(push.presentation(for: notification))
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    guard Push.isOurs(response.notification) else {
      return super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier { push.tapped(response.notification) }
    completionHandler()
  }
}
