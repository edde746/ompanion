import Foundation
import Security

/// The push key and the device id (its additional authenticated data), in the keychain group the app shares with its
/// Notification Service Extension. Compiled into both. Readable after the first unlock, because the extension decrypts
/// while the phone is locked, and never migrated to another device.
enum PushKeychain {
  enum Item: String {
    case key
    case deviceId
  }

  enum Failure: Error, CustomStringConvertible {
    case noGroup
    case status(OSStatus)

    var description: String {
      switch self {
      case .noGroup: return "the bundle names no keychain group (OmpanionKeychainGroup)"
      case .status(let status): return SecCopyErrorMessageString(status, nil) as String? ?? "keychain error \(status)"
      }
    }
  }

  static func read(_ item: Item) throws -> Data? {
    var query = try itemQuery(item)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure.status(status) }
    return result as? Data
  }

  static func write(_ item: Item, _ data: Data) throws {
    let query = try itemQuery(item)
    var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure.status(status) }
  }

  static func delete(_ item: Item) throws {
    let status = SecItemDelete(try itemQuery(item) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
  }

  private static func itemQuery(_ item: Item) throws -> [String: Any] {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "OmpanionKeychainGroup") as? String else {
      throw Failure.noGroup
    }
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "app.ompanion.push",
      kSecAttrAccount as String: item.rawValue,
      kSecAttrAccessGroup as String: group,
    ]
  }
}
