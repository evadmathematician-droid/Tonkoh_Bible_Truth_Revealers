package com.tbtrapp.calls

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import com.onesignal.notifications.INotificationReceivedEvent
import com.onesignal.notifications.INotificationServiceExtension
import com.tbtrapp.MainActivity
import com.tbtrapp.platform.ContactDisplayNames

/**
 * Wakes the app for an incoming call when it is backgrounded or fully
 * killed.
 *
 * Registered via the `com.onesignal.NotificationServiceExtension`
 * `<meta-data>` in the manifest. OneSignal's FCM service spins the process
 * up far enough to run this even from a killed state, as long as the push
 * was delivered high-priority (the Cloudflare `/push/call` route sends a
 * data-only push with `priority: 10`).
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
        // /push/call sends `isCall: true` (data only); older relays only `type`.
        val isCall = type == "incoming_call" || data?.optBoolean("isCall") == true

        if (data == null || !isCall || callId.isBlank()) {
            // Not a call push — let OneSignal display it, but with the
            // sender shown under this phone's contact naming rule.
            if (data != null) applyContactName(event, data)
            return
        }

        // Our own UI handles this from here — never show OneSignal's plain
        // notification.
        event.preventDefault(true)

        if (MainActivity.isForeground || MainActivity.flutterRinging) {
            // App is open (or Flutter's in-app RTDB listener, still alive in
            // the background, is already ringing): the incoming-call screen
            // is handled there. A second ring here would just duplicate it.
            Log.d(TAG, "call push $callId — Flutter is handling it")
            return
        }

        val ctx = event.context.applicationContext
        val callerId = data.optString("callerId")
        val callerName = if (callerId.isNotBlank()) {
            ContactDisplayNames.nameFor(ctx, callerId)
        } else {
            data.optString("callerName").ifBlank { "Someone" }
        }
        val callType = data.optString("callType").ifBlank { "audio" }

        val extras = mapOf(
            "callId" to callId,
            "callerId" to callerId,
            "callerName" to callerName,
            "callerPhoto" to data.optString("callerPhoto"),
            "chatId" to data.optString("chatId"),
            "callType" to callType,
        )
        // Rings (ringtone + vibration) until answered / declined / cancelled
        // / 45 s — see IncomingRingService. The high-priority push lets this
        // start a foreground service from the background.
        if (IncomingRingService.start(ctx, extras)) return

        try {
            NotificationManagerCompat.from(ctx).notify(
                INCOMING_CALL_NOTIF_ID,
                buildIncomingCallNotification(
                    ctx = ctx,
                    callId = callId,
                    callerId = callerId,
                    callerName = callerName,
                    callerPhoto = extras.getValue("callerPhoto"),
                    chatId = extras.getValue("chatId"),
                    callType = callType,
                ),
            )
            Log.d(TAG, "posted full-screen incoming-call notification for $callId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to post full-screen call notification", e)
        }
    }

    /**
     * Chat and feed pushes carry the sender's own profile name. Swap it for
     * the name saved in this phone's contacts, or the bare number:
     *  - private chat (`senderUid` + `chatId`): the title is the sender;
     *  - feed message (`type == "audio_message"` + `body`): "name: body".
     */
    private fun applyContactName(
        event: INotificationReceivedEvent,
        data: org.json.JSONObject,
    ) {
        val senderUid = data.optString("senderUid")
        if (senderUid.isBlank()) return
        val name = ContactDisplayNames.nameFor(event.context.applicationContext, senderUid)
        val type = data.optString("type")
        val body = data.optString("body")
        try {
            when {
                type == "audio_message" && body.isNotBlank() ->
                    event.notification.setExtender { b -> b.setContentText("$name: $body") }
                data.optString("chatId").isNotBlank() ->
                    event.notification.setExtender { b -> b.setContentTitle(name) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "couldn't apply contact name to push", e)
        }
    }

    companion object {
        private const val TAG = "CallNotifServiceExt"

        // Kept in step with CallNotifications (Dart): once Flutter is up it
        // re-posts on this same id so there is only ever one notification.
        const val CHANNEL_ID = "incoming_call_fullscreen"
        const val INCOMING_CALL_NOTIF_ID = 4241

        /** Silent channel for IncomingRingService, which plays the ringtone
         *  and vibration itself (the old channel's sound only dinged once). */
        const val RING_CHANNEL_ID = "incoming_call_ring_v2"

        const val EXTRA_CALL_ACTION = "callAction"
        const val ACTION_INCOMING = "incoming"
        const val ACTION_ACCEPT = "accept"

        /**
         * The full-screen incoming-call notification. [silent] true is the
         * ring service's version (it makes the sound); false keeps the old
         * channel's own sound for when the service couldn't start.
         */
        fun buildIncomingCallNotification(
            ctx: Context,
            callId: String,
            callerId: String,
            callerName: String,
            callerPhoto: String,
            chatId: String,
            callType: String,
            silent: Boolean = false,
        ): Notification {
            val channelId = if (silent) RING_CHANNEL_ID else CHANNEL_ID
            ensureChannel(ctx, channelId)

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
            // CallStyle: the system's own incoming-call layout (big Answer /
            // Decline buttons) on Android 12+; plain actions on older ones.
            val caller = Person.Builder().setName(callerName).setImportant(true).build()

            return NotificationCompat.Builder(ctx, channelId)
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
                .setStyle(NotificationCompat.CallStyle.forIncomingCall(caller, declinePi, acceptPi))
                .build()
        }

        private fun ensureChannel(ctx: Context, channelId: String) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(channelId) != null) return
            val channel = NotificationChannel(
                channelId,
                "Incoming calls",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Ringing screen for incoming TBTR calls"
                setBypassDnd(true)
                lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
                if (channelId == RING_CHANNEL_ID) {
                    setSound(null, null)
                    enableVibration(false)
                } else {
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 1000, 800, 1000, 800)
                }
            }
            mgr.createNotificationChannel(channel)
        }
    }
}
