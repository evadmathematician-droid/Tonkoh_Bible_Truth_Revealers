package com.tbtrapp.calls

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import androidx.core.app.NotificationCompat

/**
 * Shared notification channels/builders for the two long-running foreground
 * services that aren't already self-contained (CallService owns its own
 * "incoming call" channel directly): the in-progress call (OngoingCallService)
 * and voice-message recording (VoiceRecordingService).
 */
object CallNotifications {
    private const val CHANNEL_ID_ONGOING = "tbtr_ongoing_call"
    private const val CHANNEL_ID_RECORDING = "tbtr_voice_recording"

    const val NOTIF_ID_ONGOING = 2001
    const val NOTIF_ID_RECORDING = 2002

    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return

        if (manager.getNotificationChannel(CHANNEL_ID_ONGOING) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID_ONGOING,
                    "Ongoing call",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shown while a call is in progress"
                    setShowBadge(false)
                }
            )
        }

        if (manager.getNotificationChannel(CHANNEL_ID_RECORDING) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID_RECORDING,
                    "Voice recording",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shown while recording a voice message"
                    setShowBadge(false)
                }
            )
        }
    }

    fun buildOngoingCallNotification(
        context: Context,
        callType: String,
        peerName: String,
        statusText: String,
        endCallPendingIntent: PendingIntent
    ): Notification {
        val isVideo = callType.equals("video", ignoreCase = true)
        return NotificationCompat.Builder(context, CHANNEL_ID_ONGOING)
            .setSmallIcon(android.R.drawable.sym_action_call)
            .setContentTitle(if (isVideo) "Video call with $peerName" else "Call with $peerName")
            .setContentText(statusText)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "End call", endCallPendingIntent)
            .build()
    }

    fun buildRecordingNotification(context: Context, stopPendingIntent: PendingIntent): Notification {
        return NotificationCompat.Builder(context, CHANNEL_ID_RECORDING)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Recording voice message")
            .setContentText("Tap stop to finish")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPendingIntent)
            .build()
    }
}
