package com.tbtrapp.share

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import java.io.File
import java.util.UUID

/**
 * Share target for other apps (TikTok, WhatsApp, YouTube, gallery, …):
 * "Share → TBTR App" lands here.
 *
 * It's an invisible pass-through rather than MainActivity itself, because
 * a share starts its target inside the *sending* app's task — pointing the
 * filters at MainActivity would boot a second Flutter engine there. Instead
 * this copies the content, parks it in [ShareInbox], and brings the
 * existing app task forward exactly like tapping the launcher icon
 * (cold-starting it if needed). MainActivity hands the inbox to Flutter.
 *
 * Shared `content://` URIs are only readable while this activity is alive,
 * so files are copied into the app's cache before finishing.
 */
class ShareReceiverActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val shareIntent = intent
        if (shareIntent == null ||
            (shareIntent.action != Intent.ACTION_SEND &&
                shareIntent.action != Intent.ACTION_SEND_MULTIPLE)
        ) {
            finish()
            return
        }

        // Large videos take a moment to copy — keep it off the main thread.
        Thread {
            val payload = try {
                read(shareIntent)
            } catch (e: Exception) {
                Log.e(TAG, "couldn't read shared content", e)
                null
            }
            runOnUiThread {
                if (payload != null && !payload.isEmpty()) {
                    ShareInbox.put(payload)
                    openApp()
                }
                finish()
            }
        }.start()
    }

    private fun openApp() {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return
        launch.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED,
        )
        launch.putExtra(ShareInbox.EXTRA_HAS_SHARE, true)
        startActivity(launch)
    }

    private fun read(intent: Intent): ShareInbox.Payload {
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            ?: intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)

        val uris = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            streamList(intent)?.let { uris.addAll(it) }
        } else {
            stream(intent)?.let { uris.add(it) }
        }

        val dir = File(cacheDir, "incoming_share").apply { mkdirs() }
        val files = uris.take(MAX_FILES).mapNotNull { copy(it, dir, intent.type) }
        // Picked the "Audio Screen" Direct Share shortcut: preselect it.
        val target = if (intent.getStringExtra(Intent.EXTRA_SHORTCUT_ID) ==
            ShareShortcuts.AUDIO_SCREEN_ID
        ) "audio" else null
        return ShareInbox.Payload(text = text, subject = subject, files = files, target = target)
    }

    @Suppress("DEPRECATION")
    private fun stream(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }

    @Suppress("DEPRECATION")
    private fun streamList(intent: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }

    private fun copy(uri: Uri, dir: File, intentType: String?): ShareInbox.SharedFile? {
        return try {
            val resolver = contentResolver
            val mime = resolver.getType(uri)
                ?: intentType?.takeIf { !it.endsWith("/*") }
                ?: "application/octet-stream"
            val name = displayName(uri) ?: defaultName(mime)
            val safeName = name.replace(Regex("[^A-Za-z0-9._ -]"), "_").take(80)
            val out = File(dir, "${UUID.randomUUID()}_$safeName")
            resolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { output ->
                    val copied = input.copyTo(output)
                    if (copied > MAX_FILE_BYTES) {
                        out.delete()
                        Log.w(TAG, "shared file too large ($copied bytes), skipped")
                        return null
                    }
                }
            } ?: return null
            ShareInbox.SharedFile(path = out.absolutePath, mimeType = mime, name = name)
        } catch (e: Exception) {
            Log.w(TAG, "couldn't copy shared uri", e)
            null
        }
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    private fun defaultName(mime: String): String {
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
        return if (ext != null) "shared.$ext" else "shared"
    }

    companion object {
        private const val TAG = "ShareReceiver"
        private const val MAX_FILES = 10
        private const val MAX_FILE_BYTES = 200L * 1024 * 1024
    }
}
