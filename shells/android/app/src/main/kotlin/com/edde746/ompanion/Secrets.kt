package com.edde746.ompanion

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

private const val KEYSTORE = "AndroidKeyStore"
private const val KEY_ALIAS = "ompanion.secrets"
private const val TRANSFORMATION = "AES/GCM/NoPadding"
private const val IV_BYTES = 12
private const val TAG_BITS = 128

/**
 * shell.secretGet/Set/Delete: each value AES-GCM encrypted with a key that never leaves the Android Keystore, stored
 * as base64(iv + ciphertext) in private SharedPreferences. The secret's name is the additional data, so a ciphertext
 * moved to another name fails to decrypt. Not thread-safe: MainActivity calls it from one background thread.
 */
class Secrets(context: Context) {
    private val prefs = context.getSharedPreferences("secrets", Context.MODE_PRIVATE)
    private val key: SecretKey by lazy { loadKey() }

    fun get(name: String): String? {
        val stored = prefs.getString(name, null) ?: return null
        val sealed = Base64.decode(stored, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, sealed, 0, IV_BYTES))
        cipher.updateAAD(name.toByteArray())
        return String(cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES))
    }

    fun set(name: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        // The Keystore picks the IV: it refuses caller-chosen IVs for encryption.
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(name.toByteArray())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray())
        commit(prefs.edit().putString(name, Base64.encodeToString(sealed, Base64.NO_WRAP)), name)
    }

    fun delete(name: String) = commit(prefs.edit().remove(name), name)

    private fun commit(edit: SharedPreferences.Editor, name: String) =
        check(edit.commit()) { "could not write the secret $name" }

    private fun loadKey(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as SecretKey?)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }
}
