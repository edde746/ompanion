package com.edde746.ompanion.push

import android.content.Context
import android.content.SharedPreferences
import com.edde746.ompanion.BuildConfig
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import io.flutter.plugin.common.MethodChannel

/** A session the app shows in the foreground (`setVisible`). */
data class VisibleSession(val machineId: String, val runId: String?, val sessionPath: String?)

/** A decrypted, validated push message (docs/contracts/push.md, Payload). */
data class PushMessage(
    val machineId: String,
    val runId: String?,
    val sessionPath: String?,
    val title: String,
    val subtitle: String,
    val body: String,
) {
    /** One notification per session: a newer message for the same tag replaces the older one. */
    val tag: String
        get() = runId ?: machineId
}

fun VisibleSession.shows(message: PushMessage): Boolean =
    machineId == message.machineId &&
        ((message.runId != null && message.runId == runId) ||
            (message.sessionPath != null && message.sessionPath == sessionPath))

/** Push state shared by MainActivity and PushMessagingService, which run in the same process. */
object Push {
    const val CHANNEL = "ompanion/push"
    const val NOTIFICATION_CHANNEL = "sessions"

    // Every notification has this id; its tag tells sessions apart.
    const val NOTIFICATION_ID = 1

    const val EXTRA_MACHINE_ID = "ompanion.push.machineId"
    const val EXTRA_RUN_ID = "ompanion.push.runId"
    const val EXTRA_SESSION_PATH = "ompanion.push.sessionPath"

    // App-private preferences, never backed up (allowBackup is false). Push is on while an FID is stored.
    const val PREF_KEY = "key"
    const val PREF_DEVICE_ID = "deviceId"
    const val PREF_FID = "fid"

    @Volatile var visible: VisibleSession? = null

    /** MainActivity's channel while its engine runs. Main thread only. */
    var channel: MethodChannel? = null

    /** Null when the build has no android/firebase.properties. */
    val firebaseOptions: FirebaseOptions? =
        if (BuildConfig.FIREBASE_APPLICATION_ID.isEmpty()) {
            null
        } else {
            FirebaseOptions.Builder()
                .setProjectId(BuildConfig.FIREBASE_PROJECT_ID)
                .setApplicationId(BuildConfig.FIREBASE_APPLICATION_ID)
                .setApiKey(BuildConfig.FIREBASE_API_KEY)
                .setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID)
                .build()
        }

    fun prefs(context: Context): SharedPreferences = context.getSharedPreferences("push", Context.MODE_PRIVATE)

    fun isOn(context: Context): Boolean = prefs(context).contains(PREF_FID)

    fun startFirebase(context: Context, options: FirebaseOptions) {
        if (FirebaseApp.getApps(context).isEmpty()) FirebaseApp.initializeApp(context, options)
    }

    /** What `enable` and `registration` return, or null while push is off. */
    fun registration(context: Context): Map<String, String>? {
        val prefs = prefs(context)
        val fid = prefs.getString(PREF_FID, null) ?: return null
        val key = prefs.getString(PREF_KEY, null) ?: return null
        return mapOf("platform" to "android", "fid" to fid, "key" to key)
    }
}
