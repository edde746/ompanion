package com.edde746.ompanion

import android.annotation.SuppressLint
import android.content.Context
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.webkit.WebView
import androidx.core.view.inputmethod.EditorInfoCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import androidx.core.view.inputmethod.InputContentInfoCompat

// What keyboards may insert: stickers, GIFs and images from their clipboard, the image types omp takes as image content
// (ui/src/app/screens/chat/attachment_input.ts).
private val KEYBOARD_IMAGE_TYPES = arrayOf("image/png", "image/jpeg", "image/gif", "image/webp")

/**
 * The page's WebView, offering keyboards image insertion (commitContent) in every field it edits: [onImage] gets each
 * image a keyboard commits, on the input method's thread, and keeps it (true) or refuses it.
 */
@SuppressLint("ViewConstructor")
class KeyboardWebView(context: Context, private val onImage: (InputContentInfoCompat, flags: Int) -> Boolean) :
    WebView(context) {
    // Chromium answers null first and the real connection when the input method asks again, through its proxy view.
    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val connection = super.onCreateInputConnection(outAttrs) ?: return null
        EditorInfoCompat.setContentMimeTypes(outAttrs, KEYBOARD_IMAGE_TYPES)
        return InputConnectionCompat.createWrapper(connection, outAttrs) { content, flags, _ -> onImage(content, flags) }
    }
}
