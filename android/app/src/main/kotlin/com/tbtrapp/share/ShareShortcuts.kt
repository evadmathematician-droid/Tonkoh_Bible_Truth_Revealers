package com.tbtrapp.share

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.tbtrapp.R

/**
 * Publishes the "T.B.T.R – Audio Screen" Direct Share shortcut so it shows
 * at the top of Android's share sheet, next to recent chats. Its category
 * matches the share-target in res/xml/share_targets.xml.
 */
object ShareShortcuts {
    const val AUDIO_SCREEN_ID = "share_audio_screen"
    private const val CATEGORY = "com.tbtrapp.category.SHARE_TO_AUDIO"

    fun publish(context: Context) {
        try {
            val shortcut = ShortcutInfoCompat.Builder(context, AUDIO_SCREEN_ID)
                .setShortLabel("Audio Screen")
                .setLongLabel("T.B.T.R – Audio Screen")
                .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
                .setCategories(setOf(CATEGORY))
                .setLongLived(true)
                .setIntent(
                    Intent(Intent.ACTION_DEFAULT).setClass(context, ShareReceiverActivity::class.java),
                )
                .build()
            ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
        } catch (e: Exception) {
            Log.w("ShareShortcuts", "couldn't publish the share shortcut", e)
        }
    }
}
