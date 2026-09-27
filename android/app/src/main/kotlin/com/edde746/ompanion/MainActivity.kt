package com.edde746.ompanion

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Base64
import com.edde746.ompanion.push.Push
import com.edde746.ompanion.push.VisibleSession
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailabilityLight
import com.google.firebase.FirebaseOptions
import com.google.firebase.installations.FirebaseInstallations
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private var launchTap: Map<String, String?>? = null

    // Until Dart takes the launch tap, a later tap replaces it; afterwards taps reach Dart as `tap` events.
    private var launchTapTaken = false
    private var pendingEnable: PendingEnable? = null

    private class PendingEnable(val deviceId: String, val options: FirebaseOptions, val result: MethodChannel.Result)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A restored activity, or one reopened from recents, carries the intent of a tap that was already handled.
        if (savedInstanceState == null && (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0) {
            launchTap = tapOf(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val tap = tapOf(intent) ?: return
        if (launchTapTaken) channel.invokeMethod("tap", tap) else launchTap = tap
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, Push.CHANNEL)
        channel.setMethodCallHandler(::onPushCall)
        Push.channel = channel
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (Push.channel === channel) Push.channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_NOTIFICATIONS) finishEnable()
    }

    private fun onPushCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status())
            "enable" -> enable(requireNotNull(call.argument<String>("deviceId")) { "enable needs a deviceId" }, result)
            "registration" -> result.success(Push.registration(this))
            "disable" -> disable(result)
            "setVisible" -> {
                Push.visible =
                    call.arguments<Map<String, String?>>()?.let {
                        VisibleSession(
                            machineId = requireNotNull(it["machineId"]) { "setVisible needs a machineId" },
                            runId = it["runId"],
                            sessionPath = it["sessionPath"],
                        )
                    }
                result.success(null)
            }
            "clear" -> {
                val machineId = requireNotNull(call.argument<String>("machineId")) { "clear needs a machineId" }
                notificationManager().cancel(call.argument<String>("runId") ?: machineId, Push.NOTIFICATION_ID)
                result.success(null)
            }
            "takeLaunchTap" -> {
                launchTapTaken = true
                result.success(launchTap)
                launchTap = null
            }
            else -> result.notImplemented()
        }
    }

    private fun status(): Map<String, Any?> {
        val playServices = GoogleApiAvailabilityLight.getInstance().isGooglePlayServicesAvailable(this)
        val reason =
            when {
                Push.firebaseOptions == null -> "not configured"
                playServices != ConnectionResult.SUCCESS -> "Google Play services is unavailable"
                else -> null
            }
        return mapOf("available" to (reason == null), "reason" to reason)
    }

    private fun enable(deviceId: String, result: MethodChannel.Result) {
        val options = Push.firebaseOptions ?: return result.error("unavailable", "not configured", null)
        if (pendingEnable != null) return result.error("failed", "push is already being turned on", null)
        pendingEnable = PendingEnable(deviceId, options, result)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        } else {
            finishEnable()
        }
    }

    private fun finishEnable() {
        val pending = pendingEnable ?: return
        pendingEnable = null
        val result = pending.result
        // Covers a refused permission on Android 13 and later, and notifications turned off in the system settings.
        if (!notificationManager().areNotificationsEnabled()) {
            return result.error("denied", "notifications are off for ompanion", null)
        }
        val prefs = Push.prefs(this)
        val key =
            prefs.getString(Push.PREF_KEY, null)
                ?: Base64.encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) }, Base64.NO_WRAP)
        prefs.edit().putString(Push.PREF_KEY, key).putString(Push.PREF_DEVICE_ID, pending.deviceId).apply()
        Push.startFirebase(this, pending.options)
        FirebaseMessaging
            .getInstance()
            .register()
            .onSuccessTask { FirebaseInstallations.getInstance().id }
            .addOnCompleteListener { task ->
                if (!task.isSuccessful) {
                    result.error("failed", task.exception?.message ?: "FCM registration failed", null)
                    return@addOnCompleteListener
                }
                prefs.edit().putString(Push.PREF_FID, task.result).apply()
                result.success(Push.registration(this))
            }
    }

    // Unregisters from FCM and deletes the Firebase installation, then forgets the key, so Firebase is not
    // started on the next launch. With no key, push was never turned on and Firebase never ran. A failure leaves push
    // on, so turning it off can be retried.
    private fun disable(result: MethodChannel.Result) {
        val options = Push.firebaseOptions
        if (options == null || !Push.prefs(this).contains(Push.PREF_KEY)) {
            forgetPush()
            return result.success(null)
        }
        Push.startFirebase(this, options)
        FirebaseMessaging
            .getInstance()
            .unregister()
            .onSuccessTask { FirebaseInstallations.getInstance().delete() }
            .addOnCompleteListener { task ->
                if (!task.isSuccessful) {
                    result.error("failed", task.exception?.message ?: "FCM unregistration failed", null)
                    return@addOnCompleteListener
                }
                forgetPush()
                result.success(null)
            }
    }

    private fun forgetPush() {
        Push.prefs(this).edit().clear().apply()
        notificationManager().cancelAll()
    }

    private fun notificationManager(): NotificationManager = getSystemService(NotificationManager::class.java)

    private fun tapOf(intent: Intent): Map<String, String?>? {
        val machineId = intent.getStringExtra(Push.EXTRA_MACHINE_ID) ?: return null
        return mapOf(
            "machineId" to machineId,
            "runId" to intent.getStringExtra(Push.EXTRA_RUN_ID),
            "sessionPath" to intent.getStringExtra(Push.EXTRA_SESSION_PATH),
        )
    }

    private companion object {
        const val REQUEST_NOTIFICATIONS = 0x7075
    }
}
