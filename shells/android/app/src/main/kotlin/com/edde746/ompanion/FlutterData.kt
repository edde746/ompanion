package com.edde746.ompanion

import android.content.Context
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.security.Key
import java.security.KeyStore
import java.security.PrivateKey
import java.security.spec.MGF1ParameterSpec
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

// What the Flutter app (flutter_secure_storage 11.2.0 with its default AndroidOptions, which every release used) left
// in SharedPreferences: the values, the AES key wrapped by the Keystore's RSA key, and the algorithm markers.
private const val DATA_PREFS = "FlutterSecureStorage"
private const val KEY_PREFS = "FlutterSecureKeyStorage"
private const val CONFIG_PREFS = "FlutterSecureStorageConfiguration:FlutterSecureStorage"
private const val LEGACY_CONFIG_PREFS = "FlutterSecureStorageConfiguration"
private const val ENTRY_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_"
private const val WRAPPED_KEY = "AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"
private val ALGORITHMS =
    mapOf(
        "FlutterSecureSAlgorithmKey" to "RSA_ECB_OAEPwithSHA_256andMGF1Padding",
        "FlutterSecureSAlgorithmStorage" to "AES_GCM_NoPadding",
    )
private const val DATABASE = "ompanion.sqlite"

/**
 * shell.flutterData and shell.flutterDataClear (docs/contracts/bridge.md, Flutter import): the Flutter app's database
 * in filesDir and its secrets, decoded as flutter_secure_storage's StorageCipherImplementationGCM and
 * KeyCipherImplementationRSAOAEP do. Reads create nothing: no Keystore key, no preferences file.
 */
object FlutterData {
    /** `{database: <path> | null, secrets: {<key>: <value>}}`. */
    fun read(context: Context): JSONObject {
        val database = File(context.filesDir, DATABASE)
        val result = JSONObject().put("database", if (database.isFile) database.path else JSONObject.NULL)
        val secrets = JSONObject()
        result.put("secrets", secrets)
        val entries =
            context.getSharedPreferences(DATA_PREFS, Context.MODE_PRIVATE).all.filterKeys { it.startsWith(ENTRY_PREFIX) }
        if (entries.isEmpty()) return result
        checkAlgorithms(context)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val aes = unwrapKey(context)
        for ((name, value) in entries) {
            val key = name.removePrefix(ENTRY_PREFIX)
            val sealed = Base64.decode(value as String, Base64.DEFAULT)
            val plain =
                try {
                    cipher.init(Cipher.DECRYPT_MODE, aes, GCMParameterSpec(128, sealed, 0, 12))
                    cipher.doFinal(sealed, 12, sealed.size - 12)
                } catch (e: Exception) {
                    throw IllegalStateException("could not decrypt the Flutter app's secret $key: $e", e)
                }
            secrets.put(key, String(plain, Charsets.UTF_8))
        }
        return result
    }

    /** Deletes the secrets, their key and markers, and renames the database files to `….imported`. */
    fun clear(context: Context) {
        for (name in listOf(DATA_PREFS, KEY_PREFS, CONFIG_PREFS, LEGACY_CONFIG_PREFS)) {
            check(context.deleteSharedPreferences(name)) { "could not delete the preferences $name" }
        }
        val alias = keyAlias(context)
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        store.deleteEntry(alias)
        check(!store.containsAlias(alias)) { "could not delete the Keystore key $alias" }
        val renamed = mutableListOf<String>()
        for (suffix in listOf("", "-journal", "-wal", "-shm")) {
            val file = File(context.filesDir, DATABASE + suffix)
            if (!file.exists()) continue
            val imported = File(context.filesDir, "$DATABASE$suffix.imported")
            check(file.renameTo(imported)) { "could not rename $file to $imported" }
            renamed += imported.name
        }
        Log.i(TAG, "cleared the Flutter app's data: its secrets, the Keystore key $alias; kept the database as $renamed")
    }

    // A store some other version wrote with other ciphers would fail to decrypt here; this names the cause instead.
    private fun checkAlgorithms(context: Context) {
        val config = context.getSharedPreferences(CONFIG_PREFS, Context.MODE_PRIVATE)
        val legacy = context.getSharedPreferences(LEGACY_CONFIG_PREFS, Context.MODE_PRIVATE)
        for ((marker, expected) in ALGORITHMS) {
            val saved = config.getString(marker, null) ?: legacy.getString(marker, null) ?: continue
            check(saved == expected) { "the Flutter app's secrets use $saved, not $expected" }
        }
    }

    private fun unwrapKey(context: Context): Key {
        val wrapped =
            context.getSharedPreferences(KEY_PREFS, Context.MODE_PRIVATE).getString(WRAPPED_KEY, null)
                ?: error("the Flutter app's secrets have no wrapped key in $KEY_PREFS")
        val alias = keyAlias(context)
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val privateKey = store.getKey(alias, null) as? PrivateKey ?: error("the Keystore has no private key $alias")
        val cipher = Cipher.getInstance("RSA/ECB/OAEPPadding", "AndroidKeyStoreBCWorkaround")
        cipher.init(
            Cipher.UNWRAP_MODE,
            privateKey,
            OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT),
        )
        return cipher.unwrap(Base64.decode(wrapped, Base64.DEFAULT), "AES", Cipher.SECRET_KEY)
    }

    private fun keyAlias(context: Context) = context.packageName + ".FlutterSecureStoragePluginKeyOAEP"
}
