package com.tbtrapp.calls

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.onesignal.notifications.INotificationReceivedEvent
import com.onesignal.notifications.INotificationServiceExtension
import com.tbtrapp.MainActivity

/**
 * Wakes the app for an incoming call when it is backgrounded or fully
 * killed.
 *
 * Registered via the `com.onesignal.NotificationServiceExtension`
 * `<meta-data>` in the manifest. OneSignal's FCM service spins the process
 * up far enough to run this even from a killed state, as long as the push
 * was delivered high-priority (the Cloudflare `/send-call-push` route sends
 * `priority: 10`).
 *
 * For a call push (`data.type == "incoming_call"`) this posts a
 * **full-screen-intent** notification on a high-importance,
 * `CATEGORY_CALL` channel. That combination is what makes Android turn the
 * screen on and show our ringing UI (MainActivity → Flutter
 * `IncomingCallScreen`) from a cold start, the same way WhatsApp / Signal
 * behave. Once Flutter is running it takes over the ringtone, vibration and
 * the notification (same id) via `IncomingCallManager`.
 *
 * When the app is already in the foreground the RTDB listener in
 * `CallSignalingRepository` is already handling the call, so this bails out
 * to avoid a second notification / ring.
 *
 * This does NOT use the native Telecom stack (`TelecomCallManager` etc.) —
 * that path was retired when calling moved fully onto Flutter/WebRTC.
 */
class CallNotificationServiceExtension : INotificationServiceExtension {

    override fun onNotificationReceived(event: INotificationReceivedEvent) {
        val data = event.notification.additionalData
        val type = data?.optString("type").orEmpty()
        val callId = data?.optString("callId").orEmpty()

        if (data == null || type != "incoming_call" || callId.isBlank()) {
            // Not a call push — let OneSignal display it normally.
            return
        }

        // Our own UI handles this from here — never show OneSignal's plain
        // notification.
        event.preventDefault(true)

        if (MainActivity.isForeground) {
            // App is open: the in-app RTDB listener already rings + shows the
            // incoming-call screen. A second notification here would just
            // duplicate it.
            Log.d(TAG, "call push $callId — app foreground, letting the in-app path handle it")
            return
        }

        val ctx = event.context.applicationContext
        val callerName = data.optString("callerName").ifBlank { "Someone" }
        val callType = data.optString("callType").ifBlank { "audio" }

        try {
            showIncomingCallNotification(
                ctx = ctx,
                callId = callId,
                callerId = data.optString("callerId"),
                callerName = callerName,
                callerPhoto = data.optString("callerPhoto"),
                chatId = data.optString("chatId"),
                callType = callType,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to post full-screen call notification", e)
        }
    }

    private fun showIncomingCallNotification(
        ctx: Context,
        callId: String,
        callerId: String,
        callerName: String,
        callerPhoto: String,
        chatId: String,
        callType: String,
    ) {
        ensureChannel(ctx)

        fun launchIntent(action: String) = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_CALL_ACTION, action)
            putExtra("callId", callId)
            putExtra("callerId", callerId)
            putExtra("callerName", callerName)
            putExtra("callerPhoto", callerPhoto)
            putExtra("chatId", chatId)
            putExtra("callType", callType)
        }

        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

        val fullScreenPi = PendingIntent.getActivity(
            ctx, callId.hashCode(), launchIntent(ACTION_INCOMING), piFlags,
        )
        val acceptPi = PendingIntent.getActivity(
            ctx, callId.hashCode() + 1, launchIntent(ACTION_ACCEPT), piFlags,
        )
        val declinePi = PendingIntent.getBroadcast(
            ctx,
            callId.hashCode() + 2,
            Intent(ctx, CallDeclineReceiver::class.java).apply {
                action = CallDeclineReceiver.ACTION_DECLINE
                putExtra("callId", callId)
            },
            piFlags,
        )

        val title = if (callType == "video") "Incoming video call" else "Incoming call"

        val notif = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(callerName)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setTimeoutAfter(45_000L)
            .setFullScreenIntent(fullScreenPi, true)
            .setContentIntent(fullScreenPi)
            .addAction(0, "Decline", declinePi)
            .addAction(0, "Accept", acceptPi)
            .build()

        NotificationManagerCompat.from(ctx).notify(INCOMING_CALL_NOTIF_ID, notif)
        Log.d(TAG, "posted full-screen incoming-call notification for $callId")
    }

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Incoming calls",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Ringing screen for incoming TBTR calls"
            setBypassDnd(true)
            lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 1000, 800, 1000, 800)
        }
        mgr.createNotificationChannel(channel)
    }

    companion object {
        private const val TAG = "CallNotifServiceExt"

        // Kept in step with CallNotifications (Dart): once Flutter is up it
        // re-posts on this same id so there is only ever one notification.
        const val CHANNEL_ID = "incoming_call_fullscreen"
        const val INCOMING_CALL_NOTIF_ID = 4241

        const val EXTRA_CALL_ACTION = "callAction"
        const val ACTION_INCOMING = "incoming"
        const val ACTION_ACCEPT = "accept"
    }
}
