package com.edde746.ompanion

import android.app.Application
import com.edde746.ompanion.push.Push

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Firebase runs only while push is on, so the app does not contact Google before the user turns it on. It
        // starts here rather than in MainActivity because FCM wakes the process without an activity, for messages and
        // to refresh the registration.
        val options = Push.firebaseOptions ?: return
        if (Push.isOn(this)) Push.startFirebase(this, options)
    }
}
