package com.tbtrapp.data

import android.content.Context
import android.util.Log
import androidx.compose.runtime.mutableStateMapOf
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener

/**
 * Single source of truth for every profile photo the app shows, anywhere
 * — ContactScreen, ChatListScreen, PrivateChatScreen headers, Settings.
 * Device storage (SharedPreferences) is the DEFAULT read path: every
 * screen paints instantly from whatever's already on disk, online or
 * offline, never waiting on a network round trip just to show a face.
 *
 * One live Firebase listener per uid keeps that on-disk copy current —
 * the moment anyone changes their photo, every screen holding a
 * reference to this cache recomposes automatically, because `photos` is
 * a Compose-observable map, not a plain HashMap.
 */
object ProfilePhotoCache {

    private const val PREFS_NAME = "profile_photo_cache"

    // uid -> Base64 JPEG. Mirrors SharedPreferences in memory so Compose
    // can observe changes without re-reading disk on every recomposition.
    private val photos = mutableStateMapOf<String, String>()

    // One live listener per uid, ever, for the process lifetime.
    private val listening = mutableSetOf<String>()

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun readCached(context: Context, uid: String): String {
        photos[uid]?.let { return it }
        val onDisk = prefs(context).getString(uid, "") ?: ""
        if (onDisk.isNotBlank()) photos[uid] = onDisk
        return onDisk
    }

    private fun writeCached(context: Context, uid: String, base64: String) {
        photos[uid] = base64
        prefs(context).edit().putString(uid, base64).apply()
    }

    private fun ensureListening(context: Context, uid: String) {
        if (uid.isBlank() || uid in listening) return
        listening.add(uid)

        val ref = FirebaseDatabase.getInstance()
            .getReference("users").child(uid).child("photoUrl")
        ref.keepSynced(true)

        ref.addValueEventListener(object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val latest = snapshot.getValue(String::class.java) ?: ""
                // Only write through on a real value. A blank snapshot
                // during a sync hiccup should never flash someone's photo
                // back to initials — an actual photo removal should be a
                // deliberate call, not inferred from an empty read.
                if (latest.isNotBlank()) writeCached(context, uid, latest)
            }
            override fun onCancelled(error: DatabaseError) {
                Log.e("ProfilePhotoCache", error.message)
            }
        })
    }

    /**
     * Main entry point for every screen: returns the best photo available
     * for this uid RIGHT NOW — instant, offline-safe — and starts a live
     * listener in the background so it self-updates if it ever changes.
     */
    fun photoFor(context: Context, uid: String): String {
        if (uid.isBlank()) return ""
        ensureListening(context, uid)
        return readCached(context, uid)
    }

    /**
     * Call right after a successful save of YOUR OWN photo, so your own
     * screens update instantly instead of waiting on the Firebase
     * listener to round-trip back down. Everyone else's devices still
     * update live via the listener above.
     */
    fun updateOwn(context: Context, uid: String, base64: String) {
        writeCached(context, uid, base64)
    }
}