package com.edde746.ompanion.push

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import com.edde746.ompanion.MainActivity
import com.edde746.ompanion.R
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONException
import org.json.JSONObject
import java.security.GeneralSecurityException

/**
 * Receives the relay's data-only messages (docs/contracts/push.md, Relay), decrypts them and posts the notification
 * itself. A message that does not open, or is not version 1, or is more than 24 hours old is dropped.
 */
class PushMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val push =
            try {
                open(message.data)
            } catch (e: Exception) {
                when (e) {
                    is GeneralSecurityException, is JSONException, is IllegalArgumentException -> {
                        Log.w(TAG, "Dropped a push message: $e")
                        return
                    }
                    else -> throw e
                }
            }
        if (Push.visible?.shows(push) == true) return
        post(push)
    }

    override fun onRegistered(installationId: String) {
        val prefs = Push.prefs(this)
        // Push is off, or `enable` has not stored its FID yet and reports it itself.
        if (!Push.isOn(this) || prefs.getString(Push.PREF_FID, null) == installationId) return
        prefs.edit().putString(Push.PREF_FID, installationId).apply()
        Handler(Looper.getMainLooper()).post { Push.channel?.invokeMethod("fid", mapOf("fid" to installationId)) }
    }

    private fun open(data: Map<String, String>): PushMessage {
        require(data["v"] == "1") { "message version ${data["v"]}" }
        val prefs = Push.prefs(this)
        val key = requireNotNull(prefs.getString(Push.PREF_KEY, null)) { "push is off" }
        val deviceId = requireNotNull(prefs.getString(Push.PREF_DEVICE_ID, null)) { "push is off" }
        val plaintext =
            decryptPush(
                key = Base64.decode(key, Base64.DEFAULT),
                nonce = Base64.decode(requireNotNull(data["n"]) { "no nonce" }, Base64.DEFAULT),
                ciphertext = Base64.decode(requireNotNull(data["c"]) { "no ciphertext" }, Base64.DEFAULT),
                deviceId = deviceId,
            )
        val json = JSONObject(String(plaintext, Charsets.UTF_8))
        require(json.getInt("v") == 1) { "payload version ${json.get("v")}" }
        val age = System.currentTimeMillis() - json.getLong("ts")
        require(age <= MAX_AGE_MS) { "the message is ${age / 1000} s old" }
        return PushMessage(
            machineId = json.getString("machineId"),
            runId = json.optNullableString("runId"),
            sessionPath = json.optNullableString("sessionPath"),
            title = json.getString("title"),
            subtitle = json.getString("subtitle"),
            body = json.getString("body"),
        )
    }

    private fun post(push: PushMessage) {
        val manager = getSystemService(NotificationManager::class.java)
        val tap =
            Intent(this, MainActivity::class.java)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
                .putExtra(Push.EXTRA_MACHINE_ID, push.machineId)
                .putExtra(Push.EXTRA_RUN_ID, push.runId)
                .putExtra(Push.EXTRA_SESSION_PATH, push.sessionPath)
        // PendingIntents that differ only in their extras are one PendingIntent, so each session gets its own request
        // code; otherwise every notification would open the session of the latest one.
        val content =
            PendingIntent.getActivity(
                this,
                push.tag.hashCode(),
                tap,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(Push.NOTIFICATION_CHANNEL, "Sessions", NotificationManager.IMPORTANCE_HIGH),
                )
                Notification.Builder(this, Push.NOTIFICATION_CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this).setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL)
            }
        val notification =
            builder
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(push.title)
                .setSubText(push.subtitle)
                .setContentText(push.body)
                .setStyle(Notification.BigTextStyle().bigText(push.body))
                .setShowWhen(true)
                .setAutoCancel(true)
                .setContentIntent(content)
                .build()
        manager.notify(push.tag, Push.NOTIFICATION_ID, notification)
    }

    private companion object {
        const val TAG = "ompanion.push"
        const val MAX_AGE_MS = 24L * 60 * 60 * 1000
    }
}

private fun JSONObject.optNullableString(name: String): String? = if (isNull(name)) null else getString(name)
