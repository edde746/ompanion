package com.edde746.ompanion.push

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Opens a push message's ciphertext (docs/contracts/push.md, Encryption): AES-256-GCM with the 16-byte tag after the
 * encrypted bytes and the device id's UTF-8 bytes as additional authenticated data. Throws AEADBadTagException when
 * the message was altered or sealed for another key or device.
 */
fun decryptPush(key: ByteArray, nonce: ByteArray, ciphertext: ByteArray, deviceId: String): ByteArray {
    require(key.size == 32) { "the push key is ${key.size} bytes, not 32" }
    require(nonce.size == 12) { "the nonce is ${nonce.size} bytes, not 12" }
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
    cipher.updateAAD(deviceId.toByteArray(Charsets.UTF_8))
    return cipher.doFinal(ciphertext)
}
