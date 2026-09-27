import CryptoKit
import Foundation

/// A decrypted, validated push message (docs/contracts/push.md, Payload).
struct PushMessage: Decodable, Equatable {
  let v: Int
  let kind: String
  let machineId: String
  let runId: String?
  let sessionPath: String?
  let title: String
  let subtitle: String
  let body: String
  /// Milliseconds since the epoch, the machine's clock.
  let ts: Int64

  /// One thread per session.
  var thread: String { runId ?? machineId }
}

struct PushOpenError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// Opens a push message's ciphertext (docs/contracts/push.md, Encryption): AES-256-GCM with the 16-byte tag after the
/// encrypted bytes and the device id's UTF-8 bytes as additional authenticated data. Throws when the message was
/// altered or sealed for another key or device.
func decryptPush(key: Data, nonce: Data, ciphertext: Data, deviceId: String) throws -> Data {
  guard key.count == 32 else { throw PushOpenError("the push key is \(key.count) bytes, not 32") }
  guard nonce.count == 12 else { throw PushOpenError("the nonce is \(nonce.count) bytes, not 12") }
  guard ciphertext.count >= 16 else { throw PushOpenError("the ciphertext is shorter than its tag") }
  let box = try AES.GCM.SealedBox(
    nonce: AES.GCM.Nonce(data: nonce),
    ciphertext: ciphertext.dropLast(16),
    tag: ciphertext.suffix(16)
  )
  return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(deviceId.utf8))
}

/// Decrypts the relay's `n` and `c` and checks the payload: version 1, at most 24 hours old.
func openPush(nonce: String, ciphertext: String, key: Data, deviceId: String, now: Date) throws -> PushMessage {
  guard let nonceBytes = Data(base64Encoded: nonce), let ciphertextBytes = Data(base64Encoded: ciphertext) else {
    throw PushOpenError("the nonce or the ciphertext is not base64")
  }
  let plaintext = try decryptPush(key: key, nonce: nonceBytes, ciphertext: ciphertextBytes, deviceId: deviceId)
  let message = try JSONDecoder().decode(PushMessage.self, from: plaintext)
  guard message.v == 1 else { throw PushOpenError("payload version \(message.v)") }
  let ageMs = now.timeIntervalSince1970 * 1000 - Double(message.ts)
  guard ageMs <= 24 * 60 * 60 * 1000 else { throw PushOpenError("the message is \(Int(ageMs / 1000)) s old") }
  return message
}
