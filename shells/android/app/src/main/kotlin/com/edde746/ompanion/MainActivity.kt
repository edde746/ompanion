package com.edde746.ompanion

import android.Manifest
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.webkit.MimeTypeMap
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebViewRenderProcess
import android.webkit.WebViewRenderProcessClient
import android.widget.FrameLayout
import androidx.activity.BackEventCompat
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.ActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import androidx.core.view.inputmethod.InputContentInfoCompat
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.edde746.ompanion.push.Push
import com.edde746.ompanion.push.VisibleSession
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailabilityLight
import com.google.firebase.FirebaseOptions
import com.google.firebase.installations.FirebaseInstallations
import com.google.firebase.messaging.FirebaseMessaging
import ompcore.Ompcore
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/** The shell's logcat tag. */
const val TAG = "OmpanionShell"
private const val HOST = "appassets.androidplatform.net"
private const val PAGE = "https://$HOST/assets/ui/index.html"

// The page's `cache/<name>`: the core's cache directory (docs/contracts/bridge.md, Cache files).
private const val CACHE_PATH = "/assets/ui/cache/"
private val CACHE_HEADERS =
    mapOf(
        "Content-Security-Policy" to "sandbox",
        "X-Content-Type-Options" to "nosniff",
        "Cache-Control" to "no-cache",
    )

/**
 * The page fills the window edge to edge and keeps its content out of the insets `shell.insets` reports. Requests
 * for `shell.*` are answered here (docs/contracts/bridge.md, Shell services); every other message goes to the core.
 */
class MainActivity : ComponentActivity() {
    private lateinit var root: FrameLayout
    private lateinit var webView: WebView
    private val secrets by lazy { Secrets(this) }

    // The core's cache directory, served as `cache/`. A folder of its own: WebView keeps its HTTP cache in cacheDir,
    // and WebViewAssetLoader refuses to serve cacheDir as a whole.
    private val coreCache by lazy { File(cacheDir, "core") }

    // Keystore calls and file copies stay off the UI thread; one thread keeps the page's requests in order.
    private val io = Executors.newSingleThreadExecutor()

    // The core starts while the WebView is created and the page loads; the page's first message waits for it.
    private var coreStarted = CountDownLatch(1)

    // Counts Ompcore.start calls; a message of an earlier listener still queued for the UI thread is the dead page's.
    private var coreListener = 0

    // Made with the activity: its shell mark is the shell's first code.
    private val timing = StartupTiming()

    // The latest page's channel back to it; null until the page's first message, and again while it reloads.
    private var replyProxy: JavaScriptReplyProxy? = null
    private var insets = Insets(0.0, 0.0, 0.0, 0.0, 0.0)

    // A notification tap no page could take yet: sent after the page's first message.
    private var pendingTap: JSONObject? = null

    // The push notification tap that launched the app, until the page takes it (shell.pushTakeLaunchTap); a later tap
    // replaces it. Once it was taken, taps reach the page as shell.pushTap events.
    private var launchTap: JSONObject? = null
    private var launchTapTaken = false
    private var pendingEnable: PendingEnable? = null
    private val pushEvents: (String, JSONObject) -> Boolean = ::emit
    private var fileChooser: ValueCallback<Array<Uri>>? = null
    private var saving: Saving? = null

    // What waits for the answer to the notification permission request.
    private val notificationWaiters = mutableListOf<() -> Unit>()

    // Enabled only while the page can go back (shell.backEnabled), so on its root screen the system's back-to-home runs.
    // From Android 14 the page follows the gesture (shell.backStart, shell.backProgress, shell.backCancel); below, it
    // only gets the commit, shell.back.
    private val back =
        object : OnBackPressedCallback(false) {
            override fun handleOnBackStarted(backEvent: BackEventCompat) {
                val edge = if (backEvent.swipeEdge == BackEventCompat.EDGE_RIGHT) "right" else "left"
                emit("shell.backStart", JSONObject().put("edge", edge))
            }

            override fun handleOnBackProgressed(backEvent: BackEventCompat) {
                emit("shell.backProgress", JSONObject().put("progress", backEvent.progress.toDouble()))
            }

            override fun handleOnBackCancelled() {
                emit("shell.backCancel", JSONObject())
            }

            override fun handleOnBackPressed() {
                emit("shell.back", JSONObject())
            }
        }

    private val chooseFiles =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            // A recreated activity gets the result of its predecessor's chooser, whose page is gone.
            val callback = fileChooser ?: return@registerForActivityResult
            fileChooser = null
            callback.onReceiveValue(chosen(result))
        }

    private val createDocument =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult(), ::saved)

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            val waiters = notificationWaiters.toList()
            notificationWaiters.clear()
            for (waiter in waiters) waiter()
        }

    private val assetLoader by lazy {
        val cache = WebViewAssetLoader.InternalStoragePathHandler(this, coreCache)
        WebViewAssetLoader.Builder()
            .setDomain(HOST)
            // Before the assets handler: the first handler whose path matches answers. A downloaded HTML file opened as
            // a document runs sandboxed, in an opaque origin, never as the page that talks to the core.
            .addPathHandler(CACHE_PATH) { path -> cache.handle(path).apply { responseHeaders = CACHE_HEADERS } }
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.enableEdgeToEdge(window)
        styleSystemBars()
        super.onCreate(savedInstanceState)
        startCore()
        onBackPressedDispatcher.addCallback(this, back)
        Push.events = pushEvents
        root = FrameLayout(this)
        ViewCompat.setOnApplyWindowInsetsListener(root, ::applyInsets)
        setContentView(root)
        // A restored activity, or one reopened from recents, carries the intent of a tap that was already handled.
        if (savedInstanceState == null && intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0) {
            pendingTap = tapOf(intent)
            launchTap = pushTapOf(intent)
        }
        showPage()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        tapOf(intent)?.let { if (!emit("shell.notificationTap", it)) pendingTap = it }
        pushTapOf(intent)?.let { if (!(launchTapTaken && emit("shell.pushTap", it))) launchTap = it }
    }

    override fun onResume() {
        super.onResume()
        emit("shell.appState", JSONObject().put("active", true))
    }

    override fun onPause() {
        emit("shell.appState", JSONObject().put("active", false))
        super.onPause()
    }

    // configChanges keeps the activity through a switch of the system theme; the bars' icons follow it.
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        styleSystemBars()
    }

    override fun onDestroy() {
        replyProxy = null
        if (Push.events === pushEvents) Push.events = null
        io.shutdown()
        webView.destroy()
        super.onDestroy()
    }

    // Transparent bars without the system's contrast scrim, over the page's background (black or white, as the system
    // theme): the pane's tone runs to the screen's edges (design.md rule 13). Android 7 cannot draw dark navigation
    // icons, so there the navigation bar of the light theme is black.
    private fun styleSystemBars() {
        val light = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK != Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, window.decorView).run {
            isAppearanceLightStatusBars = light
            isAppearanceLightNavigationBars = light
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            window.navigationBarColor = if (light) Color.BLACK else Color.TRANSPARENT
        }
    }

    private fun showPage() {
        // Both load WebView's package, here after the core's thread started. Loading it on another thread while the
        // window drew (WebViewCompat.startUpWebView) made the first frame later (docs/research/web-ui/startup.md).
        check(WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            "this Android System WebView has no WebMessageListener; update it"
        }
        WebView.setWebContentsDebuggingEnabled(applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
        webView = KeyboardWebView(this, ::keyboardImage)
        // A new page starts on its root screen until it says otherwise.
        back.isEnabled = false
        timing.mark("webviewMs")
        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        webView.setBackgroundColor(if (night) Color.BLACK else Color.WHITE)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.allowFileAccess = false
        webView.settings.allowContentAccess = false
        webView.webViewClient = Client()
        webView.webChromeClient = Chrome()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) webView.setWebViewRenderProcessClient(Unresponsive())
        WebViewCompat.addWebMessageListener(webView, "ompCoreNative", setOf("https://$HOST")) { _, message, _, isMainFrame, proxy ->
            // Only the page itself talks to the core: a frame of the same origin must not take over its replies.
            if (!isMainFrame) {
                Log.e(TAG, "dropped a message from a subframe")
                return@addWebMessageListener
            }
            val text = checkNotNull(message.data) { "the page sent a message that is not text" }
            replyProxy = proxy
            val request = shellRequest(text)
            if (request != null) {
                shell(request, Reply(request.get("id"), proxy))
            } else {
                coreStarted.await()
                Ompcore.send(text)
            }
            pendingTap?.let {
                pendingTap = null
                emit("shell.notificationTap", it)
            }
        }
        root.addView(webView, MATCH_PARENT, MATCH_PARENT)
        webView.loadUrl(PAGE)
    }

    // On a thread of its own: Start may close the previous page's SSH connections.
    private fun startCore() {
        val started = CountDownLatch(1)
        coreStarted = started
        val listener = ++coreListener
        val smoke = intent.getBooleanExtra("smoke", false)
        val bench = intent.getBooleanExtra("bench", false)
        val expectImport = intent.getStringExtra("expectImport")
        thread(name = "ompcore-start") {
            Ompcore.setEnv("OMPCORE_DATA_DIR", filesDir.path)
            check(coreCache.isDirectory || coreCache.mkdirs()) { "could not create $coreCache" }
            Ompcore.setEnv("OMPCORE_CACHE_DIR", coreCache.path)
            if (smoke) Ompcore.setEnv("OMPCORE_SMOKE", "1")
            if (bench) Ompcore.setEnv("OMPCORE_BENCH", "1")
            if (expectImport != null) Ompcore.setEnv("OMPCORE_EXPECT_IMPORT", expectImport)
            Ompcore.start { message ->
                runOnUiThread {
                    if (listener == coreListener) replyProxy?.postMessage(message)
                }
            }
            started.countDown()
        }
    }

    // Only a message that can be a shell request is parsed here; the core parses everything else itself.
    private fun shellRequest(text: String): JSONObject? {
        if (!text.contains("\"method\":\"shell.")) return null
        return JSONObject(text).takeIf { it.optString("method").startsWith("shell.") }
    }

    private fun shell(request: JSONObject, reply: Reply) {
        val params = request.optJSONObject("params") ?: JSONObject()
        try {
            when (val method = request.getString("method")) {
                "shell.info" ->
                    reply.ok(
                        JSONObject()
                            .put("platform", "android")
                            .put("osVersion", Build.VERSION.RELEASE)
                            .put("appVersion", BuildConfig.VERSION_NAME)
                            .put("build", BuildConfig.VERSION_CODE.toString())
                            .put("device", Build.MODEL)
                            .put("push", Push.firebaseOptions != null),
                    )
                "shell.secretGet" ->
                    background(reply) { JSONObject().put("value", secrets.get(params.getString("key")) ?: JSONObject.NULL) }
                "shell.secretSet" ->
                    background(reply) {
                        secrets.set(params.getString("key"), params.getString("value"))
                        JSONObject()
                    }
                "shell.secretDelete" ->
                    background(reply) {
                        secrets.delete(params.getString("key"))
                        JSONObject()
                    }
                "shell.openUrl" -> {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(params.getString("url"))))
                    reply.ok()
                }
                "shell.clipboardWrite" -> {
                    getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(ClipData.newPlainText("ompanion", params.getString("text")))
                    reply.ok()
                }
                "shell.notify" -> {
                    postNotification(this, params)
                    reply.ok()
                }
                "shell.notifySchedule" -> {
                    scheduleNotification(this, params)
                    reply.ok()
                }
                "shell.notifyCancel" -> {
                    cancelNotification(this, params.get("id").toString())
                    reply.ok()
                }
                "shell.notifyPermission" -> notifyPermission(params.optBoolean("request"), reply)
                "shell.saveFile" -> saveFile(params.getString("name"), params.getString("url"), reply)
                "shell.insets" -> reply.ok(insets.toJson())
                "shell.timing" -> {
                    timing.write(params)
                    reply.ok()
                }
                "shell.backEnabled" -> {
                    back.isEnabled = params.getBoolean("enabled")
                    reply.ok()
                }
                "shell.flutterData" -> background(reply) { FlutterData.read(this) }
                "shell.flutterDataClear" ->
                    background(reply) {
                        FlutterData.clear(this)
                        JSONObject()
                    }
                "shell.pushStatus" -> reply.ok(pushStatus())
                "shell.pushEnable" -> pushEnable(params.getString("deviceId"), reply)
                "shell.pushRegistration" -> reply.ok(Push.registration(this) ?: JSONObject.NULL)
                "shell.pushDisable" -> pushDisable(reply)
                "shell.pushSetVisible" -> {
                    val machineId = params.optText("machineId")
                    Push.visible = machineId?.let { VisibleSession(it, params.optText("runId"), params.optText("sessionPath")) }
                    reply.ok()
                }
                "shell.pushClear" -> {
                    val machineId = params.getString("machineId")
                    notificationManager().cancel(params.optText("runId") ?: machineId, Push.NOTIFICATION_ID)
                    reply.ok()
                }
                "shell.pushTakeLaunchTap" -> {
                    launchTapTaken = true
                    reply.ok(launchTap ?: JSONObject.NULL)
                    launchTap = null
                }
                else -> reply.fail("unknown method $method")
            }
        } catch (e: Exception) {
            reply.fail(e)
        }
    }

    private fun background(reply: Reply, work: () -> JSONObject) =
        io.execute {
            try {
                reply.ok(work())
            } catch (e: Exception) {
                reply.fail(e)
            }
        }

    /** Sends a shell event to the page; false when no page can take it yet. */
    private fun emit(event: String, params: JSONObject): Boolean {
        val proxy = replyProxy ?: return false
        proxy.postMessage(JSONObject().put("event", event).put("params", params).toString())
        return true
    }

    private fun tapOf(intent: Intent): JSONObject? = intent.getStringExtra(EXTRA_TAP)?.let(::JSONObject)

    // PushMessagingService's notifications carry these extras, as the Flutter app's did.
    private fun pushTapOf(intent: Intent): JSONObject? {
        val machineId = intent.getStringExtra(Push.EXTRA_MACHINE_ID) ?: return null
        return JSONObject()
            .put("machineId", machineId)
            .put("runId", intent.getStringExtra(Push.EXTRA_RUN_ID) ?: JSONObject.NULL)
            .put("sessionPath", intent.getStringExtra(Push.EXTRA_SESSION_PATH) ?: JSONObject.NULL)
    }

    // The page lays out the whole window and keeps its content out of these, so the WebView gets none of them: it
    // neither pads for the bars nor reacts to the keyboard on its own.
    private fun applyInsets(view: View, windowInsets: WindowInsetsCompat): WindowInsetsCompat {
        val bars = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
        val keyboard = windowInsets.getInsets(WindowInsetsCompat.Type.ime()).bottom
        val density = view.resources.displayMetrics.density.toDouble()
        val next = Insets(bars.top / density, bars.right / density, bars.bottom / density, bars.left / density, keyboard / density)
        if (next != insets) {
            insets = next
            emit("shell.insets", next.toJson())
        }
        return WindowInsetsCompat.CONSUMED
    }

    private fun notificationManager(): NotificationManager = getSystemService(NotificationManager::class.java)

    private fun notificationsEnabled() = notificationManager().areNotificationsEnabled()

    private fun notifyPermission(request: Boolean, reply: Reply) {
        if (!request) return reply.ok(JSONObject().put("granted", notificationsEnabled()))
        askNotifications { reply.ok(JSONObject().put("granted", notificationsEnabled())) }
    }

    /** Asks for the notification permission where Android has one to ask for and the app lacks it, then runs [then]. */
    private fun askNotifications(then: () -> Unit) {
        val askable =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        if (!askable) return then()
        notificationWaiters += then
        if (notificationWaiters.size == 1) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun pushStatus(): JSONObject {
        val playServices = GoogleApiAvailabilityLight.getInstance().isGooglePlayServicesAvailable(this)
        val reason =
            when {
                Push.firebaseOptions == null -> "not configured"
                playServices != ConnectionResult.SUCCESS -> "Google Play services is unavailable"
                else -> null
            }
        return JSONObject().put("available", reason == null).put("reason", reason ?: JSONObject.NULL)
    }

    private fun pushEnable(deviceId: String, reply: Reply) {
        val options = Push.firebaseOptions ?: return reply.fail("not configured", "unavailable")
        if (pendingEnable != null) return reply.fail("push is already being turned on", "failed")
        pendingEnable = PendingEnable(deviceId, options, reply)
        askNotifications(::finishEnable)
    }

    private fun finishEnable() {
        val pending = pendingEnable ?: return
        pendingEnable = null
        val reply = pending.reply
        // Covers a refused permission on Android 13 and later, and notifications turned off in the system settings.
        if (!notificationsEnabled()) return reply.fail("notifications are off for ompanion", "denied")
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
                    reply.fail(task.exception?.message ?: "FCM registration failed", "failed")
                    return@addOnCompleteListener
                }
                prefs.edit().putString(Push.PREF_FID, task.result).apply()
                reply.ok(checkNotNull(Push.registration(this)))
            }
    }

    // Unregisters from FCM and deletes the Firebase installation, then forgets the key, so Firebase is not started on
    // the next launch. With no key, push was never turned on and Firebase never ran. A failure leaves push on, so
    // turning it off can be retried.
    private fun pushDisable(reply: Reply) {
        val options = Push.firebaseOptions
        if (options == null || !Push.prefs(this).contains(Push.PREF_KEY)) {
            forgetPush()
            return reply.ok()
        }
        Push.startFirebase(this, options)
        FirebaseMessaging
            .getInstance()
            .unregister()
            .onSuccessTask { FirebaseInstallations.getInstance().delete() }
            .addOnCompleteListener { task ->
                if (!task.isSuccessful) {
                    reply.fail(task.exception?.message ?: "FCM unregistration failed", "failed")
                    return@addOnCompleteListener
                }
                forgetPush()
                reply.ok()
            }
    }

    private fun forgetPush() {
        Push.prefs(this).edit().clear().apply()
        notificationManager().cancelAll()
    }

    // KeyboardWebView's image from a keyboard, on the input method's thread: copied into the core's cache and handed to
    // the page as shell.pasteFiles (docs/contracts/bridge.md).
    private fun keyboardImage(content: InputContentInfoCompat, flags: Int): Boolean {
        if (flags and InputConnectionCompat.INPUT_CONTENT_GRANT_READ_URI_PERMISSION != 0) {
            try {
                content.requestPermission()
            } catch (e: SecurityException) {
                Log.e(TAG, "the keyboard's image ${content.contentUri} is not readable", e)
                return false
            }
        }
        val mimeType = content.description.getMimeType(0)
        val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType) ?: "bin"
        val name = "pasted-${UUID.randomUUID()}.$extension"
        io.execute {
            try {
                val input =
                    checkNotNull(contentResolver.openInputStream(content.contentUri)) { "no content at ${content.contentUri}" }
                input.use { File(coreCache, name).outputStream().use(it::copyTo) }
                val file = JSONObject().put("url", "cache/$name").put("name", name).put("mimeType", mimeType)
                runOnUiThread { emit("shell.pasteFiles", JSONObject().put("files", JSONArray().put(file))) }
                Log.i(TAG, "keyboard image ${content.contentUri} ($mimeType) is cache/$name")
            } catch (e: Exception) {
                Log.e(TAG, "could not copy the keyboard's image ${content.contentUri}", e)
            } finally {
                content.releasePermission()
            }
        }
        return true
    }

    private fun saveFile(name: String, url: String, reply: Reply) {
        check(saving == null) { "a save panel is already open" }
        val file = cacheFile(url)
        check(file.isFile) { "no file at $url" }
        val type =
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
                ?: "application/octet-stream"
        createDocument.launch(
            Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType(type)
                .putExtra(Intent.EXTRA_TITLE, name),
        )
        saving = Saving(file, reply)
    }

    private fun saved(result: ActivityResult) {
        // A recreated activity gets the result of its predecessor's save panel, whose page is gone.
        val pending = saving ?: return
        saving = null
        val target = result.data?.data
        if (result.resultCode != RESULT_OK || target == null) return pending.reply.ok(JSONObject().put("saved", false))
        background(pending.reply) {
            checkNotNull(contentResolver.openOutputStream(target, "wt")) { "could not open $target" }.use { out ->
                pending.file.inputStream().use { it.copyTo(out) }
            }
            JSONObject().put("saved", true)
        }
    }

    /** The file a page URL under `cache/` serves. */
    private fun cacheFile(url: String): File {
        val resolved = URI(PAGE).resolve(url)
        require(resolved.host == HOST && resolved.path.startsWith(CACHE_PATH)) { "not a cache/ URL: $url" }
        val file = File(coreCache, resolved.path.removePrefix(CACHE_PATH)).canonicalFile
        require(file.path.startsWith(coreCache.canonicalPath + File.separator)) { "outside the cache: $url" }
        return file
    }

    private fun chosen(result: ActivityResult): Array<Uri>? {
        val data = result.data
        if (result.resultCode != RESULT_OK || data == null) return null
        val clip = data.clipData ?: return data.data?.let { arrayOf(it) }
        return Array(clip.itemCount) { clip.getItemAt(it).uri }
    }

    private class Saving(val file: File, val reply: Reply)

    private class PendingEnable(val deviceId: String, val options: FirebaseOptions, val reply: Reply)

    private data class Insets(val top: Double, val right: Double, val bottom: Double, val left: Double, val keyboard: Double) {
        fun toJson(): JSONObject =
            JSONObject().put("top", top).put("right", right).put("bottom", bottom).put("left", left).put("keyboard", keyboard)
    }

    /** One shell request's answer, for the page that asked: a reloaded page never gets its predecessor's. */
    private inner class Reply(private val id: Any, private val proxy: JavaScriptReplyProxy) {
        /** [result] is a JSONObject, or JSONObject.NULL. */
        fun ok(result: Any = JSONObject()) = post(JSONObject().put("id", id).put("result", result))

        fun fail(error: Exception) = fail(error.message ?: error.toString())

        /** [code]: the error's machine-readable code (docs/contracts/bridge.md, Error codes). */
        fun fail(message: String, code: String? = null) =
            post(JSONObject().put("id", id).put("error", JSONObject().put("message", message).putOpt("code", code)))

        private fun post(message: JSONObject) = runOnUiThread { proxy.postMessage(message.toString()) }
    }

    private inner class Chrome : WebChromeClient() {
        override fun onShowFileChooser(
            view: WebView,
            callback: ValueCallback<Array<Uri>>,
            params: FileChooserParams,
        ): Boolean {
            val intent =
                params.createIntent().putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.mode == FileChooserParams.MODE_OPEN_MULTIPLE)
            try {
                chooseFiles.launch(intent)
            } catch (e: ActivityNotFoundException) {
                // false: WebView cancels the chooser itself.
                Log.e(TAG, "no app picks files", e)
                return false
            }
            fileChooser = callback
            return true
        }
    }

    private inner class Client : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
            assetLoader.shouldInterceptRequest(request.url)

        // Links open only through shell.openUrl, which the page calls after asking the user: the main frame never
        // leaves the app, and no navigation is handed to the browser. Subframes (the agent-HTML frame and what its page
        // embeds) load what the pages' policies allow. With multiple windows off, window.open and target=_blank come
        // here as main-frame navigations.
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url
            if (!request.isForMainFrame || (url.scheme == "https" && url.host == HOST)) return false
            Log.w(TAG, "blocked a navigation to ${url.scheme}://${url.host}")
            return true
        }

        // The renderer crashed, the system reclaimed it or Unresponsive ended it: a fresh WebView reloads the page; the
        // core keeps running.
        @RequiresApi(Build.VERSION_CODES.O)
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            Log.e(TAG, "the renderer is gone (crashed: ${detail.didCrash()}); reloading the page")
            replyProxy = null
            fileChooser = null
            root.removeView(view)
            view.destroy()
            // Start again releases what the dead page opened: streams, forwards, SSH machines
            // (docs/contracts/bridge.md, Core bindings).
            startCore()
            showPage()
            return true
        }
    }

    // An agent's page shares the app page's renderer here, so one that never yields (an endless loop) stops the app
    // too. Once the renderer misses an input event or a navigation for a few seconds, it is ended, and
    // onRenderProcessGone loads the page again.
    @RequiresApi(Build.VERSION_CODES.Q)
    private inner class Unresponsive : WebViewRenderProcessClient() {
        override fun onRenderProcessUnresponsive(view: WebView, renderer: WebViewRenderProcess?) {
            Log.e(TAG, "the renderer is unresponsive; ending it")
            if (renderer?.terminate() != true) Log.e(TAG, "ending the unresponsive renderer failed")
        }

        override fun onRenderProcessResponsive(view: WebView, renderer: WebViewRenderProcess?) = Unit
    }
}

/**
 * The launch's `shell timing` line (docs/contracts/bridge.md, Shell services: shell.timing), logged once, when the
 * launch's page reports: the process's start as epoch ms, then ms from it to the activity's creation, to the WebView's
 * and to each stage the page reports, in the order they happened. UI thread only.
 */
private class StartupTiming {
    private val startElapsedMs = Process.getStartElapsedRealtime()
    private val startEpochMs = System.currentTimeMillis() - (SystemClock.elapsedRealtime() - startElapsedMs)
    private val stages = mutableListOf("shellMs" to sinceStart())
    private var written = false

    private fun sinceStart() = SystemClock.elapsedRealtimeNanos() / 1e6 - startElapsedMs

    /** The first time of `name`: a recreated WebView does not count. */
    fun mark(name: String) {
        if (stages.none { it.first == name }) stages.add(name to sinceStart())
    }

    /** `page` maps each of the page's stages to its epoch ms. */
    fun write(page: JSONObject) {
        if (written) return
        written = true
        for (name in page.keys()) stages.add("${name}Ms" to page.getDouble(name) - startEpochMs)
        stages.sortBy { it.second }
        val line = JSONObject().put("processStartEpochMs", startEpochMs)
        for ((name, ms) in stages) line.put(name, Math.round(ms * 10) / 10.0)
        Log.i(TAG, "shell timing $line")
    }
}
