package com.tbtrapp.calls

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * A minimal foreground service that runs for the lifetime of an active call
 * so Android doesn't kill the process (and the WebRTC connection with it)
 * while the call screen is backgrounded.
 *
 * The Flutter side ([OngoingCallManager]) starts it when a call connects
 * (`com.tbtrapp/calls` → `startCallForeground`) and stops it on hang-up.
 * It's `microphone` type (plus `camera` for a video call) — the permissions
 * are already declared and granted for the call itself.
 *
 * This does NOT replace the in-app WebRTC/signalling — it's purely a
 * process-keepalive + a persistent "ongoing call" notification.
 */
class CallForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val callType = intent?.getStringExtra(EXTRA_CALL_TYPE) ?: "audio"
        val peerName = intent?.getStringExtra(EXTRA_PEER_NAME).orEmpty()
        val isVideo = callType == "video"

        ensureChannel()
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(if (isVideo) "Video call" else "Voice call")
            .setContentText(peerName.ifBlank { "Ongoing call" })
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (isVideo && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                }
                startForeground(NOTIF_ID, notification, type)
            } else {
                startForeground(NOTIF_ID, notification)
            }
        } catch (e: Exception) {
            // e.g. ForegroundServiceStartNotAllowedException if we somehow
            // got here from the background — the call still works, it's just
            // less protected.
            Log.w(TAG, "startForeground failed: ${e.message}")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        mgr.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Ongoing call",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) },
        )
    }

    companion object {
        private const val TAG = "CallForegroundService"
        private const val CHANNEL_ID = "ongoing_call_fgs"
        private const val NOTIF_ID = 4243
        private const val EXTRA_CALL_TYPE = "callType"
        private const val EXTRA_PEER_NAME = "peerName"
        private const val ACTION_STOP = "com.tbtrapp.calls.action.STOP_CALL_FGS"

        fun start(context: Context, callType: String, peerName: String) {
            val intent = Intent(context, CallForegroundService::class.java).apply {
                putExtra(EXTRA_CALL_TYPE, callType)
                putExtra(EXTRA_PEER_NAME, peerName)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, CallForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                context.startService(intent)
            } catch (_: Exception) {
                context.stopService(Intent(context, CallForegroundService::class.java))
            }
        }
    }
}
