package com.tbtrapp.calls


import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
/**
 * Central place for every call/recording notification channel + builder.
 * Keeping this in one file means the "fire instantly" behavior is consistent
 * everywhere instead of re-implemented per service.
 */
object CallNotifications {

    const val CHANNEL_INCOMING = "incoming_call_channel"
    const val CHANNEL_ONGOING = "ongoing_call_channel"
    const val CHANNEL_RECORDING = "voice_recording_channel"
    const val CHANNEL_LISTENER = "call_listener_channel"

    const val NOTIF_ID_INCOMING = 4241
    const val NOTIF_ID_ONGOING = 4242
    const val NOTIF_ID_RECORDING = 4243
    const val NOTIF_ID_LISTENER = 4244

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java)

        // Incoming call: MAX importance, has its own ringtone/vibration, heads-up + full-screen.
        //
        // FIX: RingtoneManager.getActualDefaultRingtoneUri() crashes with
        // SecurityException("...was not granted this permission: WRITE_SETTINGS")
        // on some Transsion/Infinix (XOS) ROMs — that vendor's implementation
        // performs an internal write-back this app never asked for and
        // doesn't hold WRITE_SETTINGS for. Settings.System.DEFAULT_RINGTONE_URI
        // is a static content URI reference — a pure read, no vendor side
        // effect — and is what stock AOSP effectively resolves to anyway.
        val ringtoneUri: Uri = try {
            Settings.System.DEFAULT_RINGTONE_URI
        } catch (e: SecurityException) {
            Log.w("CallNotifications", "Ringtone URI lookup failed, falling back", e)
            Settings.System.DEFAULT_NOTIFICATION_URI
        }
        val audioAttrs = android.media.AudioAttributes.Builder()
            .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val incoming = NotificationChannel(
            CHANNEL_INCOMING, "Incoming Calls", NotificationManager.IMPORTANCE_HIGH
        ).apply {
            setSound(ringtoneUri, audioAttrs)
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 800, 500, 800)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setBypassDnd(true)
        }

        val ongoing = NotificationChannel(
            CHANNEL_ONGOING, "Ongoing Calls", NotificationManager.IMPORTANCE_LOW
        )
        val recording = NotificationChannel(
            CHANNEL_RECORDING, "Voice Recording", NotificationManager.IMPORTANCE_LOW
        )
        val listenerCh = NotificationChannel(
            CHANNEL_LISTENER, "Call Availability", NotificationManager.IMPORTANCE_MIN
        ).apply { setShowBadge(false) }

        nm.createNotificationChannel(incoming)
        nm.createNotificationChannel(ongoing)
        nm.createNotificationChannel(recording)
        nm.createNotificationChannel(listenerCh)
    }

    /** High-priority, full-screen ringing notification — fires the instant a call comes in. */
    fun buildIncomingCallNotification(
        context: Context,
        callId: String,
        callType: String,
        callerName: String
    ): Notification {
        val fullScreenIntent = OngoingCallActivity.buildIntent(
            context = context,
            callId = callId,
            callType = callType,
            isCaller = false,
            peerName = callerName
        )
        val fullScreenPending = PendingIntent.getActivity(
            context, callId.hashCode(), fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val acceptIntent = Intent(context, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_ACCEPT
            putExtra("call_id", callId)
            putExtra("call_type", callType)
            putExtra("peer_name", callerName)
        }
        val declineIntent = Intent(context, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_DECLINE
            putExtra("call_id", callId)
        }
        val acceptPending = PendingIntent.getBroadcast(
            context, callId.hashCode() + 1, acceptIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val declinePending = PendingIntent.getBroadcast(
            context, callId.hashCode() + 2, declineIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val title = if (callType.equals("video", true)) "Incoming video call" else "Incoming voice call"

        return NotificationCompat.Builder(context, CHANNEL_INCOMING)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle(title)
            .setContentText(callerName)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(fullScreenPending, true)
            .setContentIntent(fullScreenPending)
            .addAction(0, "Decline", declinePending)
            .addAction(0, "Accept", acceptPending)
            .setAutoCancel(true)
            .setOngoing(true)
            .setTimeoutAfter(30_000L)
            .build()
    }

    fun buildOngoingCallNotification(
        context: Context,
        callType: String,
        peerName: String,
        statusText: String,
        endPendingIntent: PendingIntent
    ): Notification {
        val title = if (callType.equals("video", true)) "Video call" else "Voice call"
        return NotificationCompat.Builder(context, CHANNEL_ONGOING)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle(title)
            .setContentText("$peerName • $statusText")
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .addAction(0, "End", endPendingIntent)
            .build()
    }

    fun buildRecordingNotification(context: Context, stopPendingIntent: PendingIntent): Notification {
        return NotificationCompat.Builder(context, CHANNEL_RECORDING)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Recording voice message")
            .setOngoing(true)
            .addAction(0, "Stop", stopPendingIntent)
            .build()
    }

    fun buildListenerNotification(context: Context): Notification {
        return NotificationCompat.Builder(context, CHANNEL_LISTENER)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle("Ready for calls")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .build()
    }
}