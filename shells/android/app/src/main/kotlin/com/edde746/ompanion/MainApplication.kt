package com.edde746.ompanion

import android.app.Application
import android.util.Log
import com.edde746.ompanion.push.Push
import com.google.firebase.messaging.FirebaseMessaging

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Firebase runs only while push is on, so the app does not contact Google before the user turns it on. It
        // starts here rather than in MainActivity because FCM wakes the process without an activity, for messages and
        // to refresh the registration.
        val options = Push.firebaseOptions ?: return
        if (!Push.isOn(this)) return
        Push.startFirebase(this, options)
        // FCM auto-init stays off (the manifest): turning it on at run time starts a sync that blocks on a Task, which
        // throws on the main thread. register() renews the registration only when the FID or the app version changed.
        FirebaseMessaging.getInstance().register().addOnFailureListener { error ->
            Log.w("ompanion", "FCM registration refresh failed", error)
        }
    }
}
