package com.tbtrapp.presence

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Brings [PresenceService] back after the phone restarts and after the app
 * is updated (Android stops it in both cases). Both broadcasts may start a
 * foreground service from the background.
 */
class PresenceBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            -> PresenceService.startIfEnabled(context)
        }
    }
}
