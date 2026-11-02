package com.edde746.ompanion

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import org.json.JSONObject

/** MainActivity's intent extra on a notification tap: the `shell.notificationTap` params as JSON text. */
const val EXTRA_TAP = "com.edde746.ompanion.tap"

// The channel of a notification whose params name none.
private const val DEFAULT_CHANNEL_ID = "notifications"
private const val DEFAULT_CHANNEL_NAME = "Notifications"

/**
 * Posts shell.notify's `{id, title, subtitle?, body, threadId?, data?, channel?: {id, name}}`; a newer one with the same
 * id replaces it. A tap opens MainActivity with the event's params in [EXTRA_TAP].
 */
fun postNotification(context: Context, params: JSONObject) {
    val id = params.get("id")
    val manager = context.getSystemService(NotificationManager::class.java)
    val tap =
        Intent(context, MainActivity::class.java)
            // PendingIntents that differ only in their extras are one PendingIntent: the id in the data keeps each
            // notification's tap its own.
            .setData(notificationUri(id.toString()))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_TAP, JSONObject().put("id", id).put("data", params.opt("data") ?: JSONObject.NULL).toString())
    val content =
        PendingIntent.getActivity(context, 0, tap, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    val builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = params.optJSONObject("channel")
            val channelId = channel?.getString("id") ?: DEFAULT_CHANNEL_ID
            // Creating an existing channel only renames it: the user's own settings for it stay.
            manager.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    channel?.getString("name") ?: DEFAULT_CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_HIGH,
                ),
            )
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL)
        }
    val body = params.getString("body")
    val notification =
        builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(params.getString("title"))
            .setSubText(params.optText("subtitle"))
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setGroup(params.optText("threadId"))
            .setShowWhen(true)
            .setAutoCancel(true)
            .setContentIntent(content)
            .build()
    manager.notify(id.toString(), 0, notification)
}

/**
 * shell.notifySchedule: an inexact alarm posts it at `atMs`, with or without the app running. The params wait in
 * SharedPreferences until then, so [ScheduledNotifications] can arm the alarm again after a reboot.
 */
fun scheduleNotification(context: Context, params: JSONObject) {
    val id = params.get("id").toString()
    check(scheduled(context).edit().putString(id, params.toString()).commit()) { "could not keep notification $id" }
    arm(context, id, params.getLong("atMs"))
}

/** shell.notifyCancel: removes the notification if it is shown, and its alarm if it is scheduled. */
fun cancelNotification(context: Context, id: String) {
    check(scheduled(context).edit().remove(id).commit()) { "could not forget notification $id" }
    context.getSystemService(AlarmManager::class.java).cancel(alarm(context, id))
    context.getSystemService(NotificationManager::class.java).cancel(id, 0)
}

/**
 * Posts a scheduled notification when its alarm goes off; arms every alarm again after a reboot (QUICKBOOT_POWERON:
 * the fast boot of some HTC and other phones, which sends no BOOT_COMPLETED) or an update.
 */
class ScheduledNotifications : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val scheduled = scheduled(context)
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
            ->
                for ((id, text) in scheduled.all) arm(context, id, JSONObject(text as String).getLong("atMs"))
            null -> {
                val id = checkNotNull(intent.data) { "an alarm without its notification id" }.schemeSpecificPart
                // Cancelled while its alarm was already on its way.
                val text = scheduled.getString(id, null) ?: return
                check(scheduled.edit().remove(id).commit()) { "could not forget notification $id" }
                postNotification(context, JSONObject(text))
            }
            else -> error("unexpected broadcast ${intent.action}")
        }
    }
}

private fun scheduled(context: Context) = context.getSharedPreferences("scheduled-notifications", Context.MODE_PRIVATE)

private fun arm(context: Context, id: String, atMs: Long) =
    context.getSystemService(AlarmManager::class.java).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, alarm(context, id))

private fun alarm(context: Context, id: String): PendingIntent =
    PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, ScheduledNotifications::class.java).setData(notificationUri(id)),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

private fun notificationUri(id: String): Uri = Uri.fromParts("ompanion-notification", id, null)

/** The string at [name], or null when it is missing or JSON null (optString would return "null"). */
fun JSONObject.optText(name: String): String? = if (isNull(name)) null else getString(name)
