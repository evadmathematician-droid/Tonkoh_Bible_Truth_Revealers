package com.tbtrapp.calls

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.DatabaseReference
import com.google.firebase.database.ValueEventListener
import com.tbtrapp.MainActivity
import com.tbtrapp.platform.AppDatabase
import com.tbtrapp.platform.RingtonePlayer

/**
 * Rings for an incoming call while the app is closed or in the background,
 * until the call is answered, declined, cancelled by the caller, times out
 * (45 s), or Flutter takes over the ringing.
 *
 * Started by [CallNotificationServiceExtension] from the high-priority call
 * push. It runs as a phone-call foreground service whose notification IS the
 * full-screen incoming-call notification, because:
 *  - a full-screen intent only launches the ringing screen when the phone is
 *    locked or idle; on an unlocked phone (say, in TikTok) Android shows a
 *    heads-up banner instead, Flutter never starts, and the old notification
 *    just "dinged" once. This service plays the real looping ringtone and
 *    vibration in either case;
 *  - a plain background process is frozen or killed within seconds on
 *    Android 14 / XOS, which would cut the ring off.
 *
 * It watches `calls/{callId}/state` so it stops the moment the caller hangs
 * up or the call is answered elsewhere, and leaves a "Missed call"
 * notification when nobody answered.
 */
class IncomingRingService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private var callId: String? = null
    private var callerName = ""
    private var callType = "audio"
    private var chatId = ""
    private var stateRef: DatabaseReference? = null
    private var stateListener: ValueEventListener? = null
    private var sawRinging = false
    private var finished = false
    private val timeout = Runnable { finish(removeNotification = true, missed = true) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra("callId")
        if (intent == null || id.isNullOrBlank()) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (id == callId && !finished) return START_NOT_STICKY // same call, already ringing

        detach()
        instance = this
        finished = false
        sawRinging = false
        callId = id
        callerName = intent.getStringExtra("callerName").orEmpty()
        callType = intent.getStringExtra("callType").orEmpty().ifBlank { "audio" }
        chatId = intent.getStringExtra("chatId").orEmpty()

        val notification = CallNotificationServiceExtension.buildIncomingCallNotification(
            ctx = this,
            callId = id,
            callerId = intent.getStringExtra("callerId").orEmpty(),
            callerName = callerName,
            callerPhoto = intent.getStringExtra("callerPhoto").orEmpty(),
            chatId = chatId,
            callType = callType,
            silent = true,
        )
        try {
            ServiceCompat.startForeground(
                this,
                CallNotificationServiceExtension.INCOMING_CALL_NOTIF_ID,
                notification,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                } else {
                    0
                },
            )
        } catch (e: Exception) {
            // Not allowed to run in the foreground right now: still show the
            // notification and ring for as long as the process lives.
            Log.w(TAG, "startForeground failed, ringing without it", e)
            NotificationManagerCompat.from(this).notify(
                CallNotificationServiceExtension.INCOMING_CALL_NOTIF_ID, notification,
            )
        }

        RingtonePlayer.shared(this).start()
        startVibration()
        watchState(id)
        handler.postDelayed(timeout, RING_TIMEOUT_MS)
        Log.d(TAG, "ringing for $id")
        return START_NOT_STICKY
    }

    private fun watchState(id: String) {
        val ref = AppDatabase.get().getReference("calls").child(id).child("state")
        val listener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val state = snapshot.getValue(String::class.java)?.uppercase()
                when {
                    state == "RINGING" -> sawRinging = true
                    // The call node may not have reached this phone yet.
                    state == null && !sawRinging -> Unit
                    state == "ACCEPTED" || state == "DECLINED" ->
                        finish(removeNotification = true, missed = false)
                    else -> finish(removeNotification = true, missed = true)
                }
            }

            override fun onCancelled(error: DatabaseError) {
                Log.w(TAG, "call state unavailable: ${error.message}")
            }
        }
        stateRef = ref
        stateListener = listener
        ref.addValueEventListener(listener)
    }

    @Suppress("DEPRECATION")
    private fun startVibration() {
        val audio = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        if (audio?.ringerMode == AudioManager.RINGER_MODE_SILENT) return
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        val pattern = longArrayOf(0, 1000, 1000)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    VibrationEffect.createWaveform(pattern, 0),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .build(),
                )
            } else {
                vibrator.vibrate(pattern, 0)
            }
        } catch (e: Exception) {
            Log.w(TAG, "vibration failed", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun stopVibration() {
        (getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)?.cancel()
    }

    private fun detach() {
        handler.removeCallbacks(timeout)
        stateListener?.let { stateRef?.removeEventListener(it) }
        stateListener = null
        stateRef = null
    }

    /**
     * Stops ringing. [removeNotification] false leaves the notification for
     * Flutter, which re-posts it on the same id when it takes over.
     */
    fun finish(removeNotification: Boolean, missed: Boolean) {
        if (finished) return
        finished = true
        detach()
        RingtonePlayer.shared(this).stop()
        stopVibration()
        ServiceCompat.stopForeground(
            this,
            if (removeNotification) {
                ServiceCompat.STOP_FOREGROUND_REMOVE
            } else {
                ServiceCompat.STOP_FOREGROUND_DETACH
            },
        )
        if (removeNotification) {
            NotificationManagerCompat.from(this)
                .cancel(CallNotificationServiceExtension.INCOMING_CALL_NOTIF_ID)
        }
        if (missed) showMissedCall()
        Log.d(TAG, "stopped for $callId (missed=$missed)")
        if (instance === this) instance = null
        stopSelf()
    }

    private fun showMissedCall() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val mgr = getSystemService(NotificationManager::class.java)
                if (mgr.getNotificationChannel(MISSED_CHANNEL_ID) == null) {
                    mgr.createNotificationChannel(
                        NotificationChannel(
                            MISSED_CHANNEL_ID, "Missed Calls",
                            NotificationManager.IMPORTANCE_HIGH,
                        ).apply { description = "Alerts for calls you missed" },
                    )
                }
            }
            val open = PendingIntent.getActivity(
                this, MISSED_NOTIF_BASE,
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(this, MISSED_CHANNEL_ID)
                .setSmallIcon(applicationInfo.icon)
                .setContentTitle(if (callType == "video") "Missed video call" else "Missed voice call")
                .setContentText(callerName.ifBlank { "Someone called you" })
                .setCategory(NotificationCompat.CATEGORY_MISSED_CALL)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(open)
                .build()
            NotificationManagerCompat.from(this)
                .notify(MISSED_NOTIF_BASE + (chatId.hashCode() and 0x7fff), notification)
        } catch (e: SecurityException) {
            Log.w(TAG, "no permission to post the missed-call notification", e)
        }
    }

    override fun onDestroy() {
        if (!finished) {
            detach()
            RingtonePlayer.shared(this).stop()
            stopVibration()
        }
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "IncomingRingService"
        private const val RING_TIMEOUT_MS = 45_000L
        private const val MISSED_CHANNEL_ID = "missed_call_channel" // same as Dart
        private const val MISSED_NOTIF_BASE = 4250

        @Volatile
        private var instance: IncomingRingService? = null

        val isRinging: Boolean get() = instance?.finished == false

        /** Starts ringing for a call push. Returns false if it couldn't start. */
        fun start(ctx: Context, extras: Map<String, String>): Boolean = try {
            val intent = Intent(ctx, IncomingRingService::class.java)
            extras.forEach { (k, v) -> intent.putExtra(k, v) }
            ContextCompat.startForegroundService(ctx, intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "couldn't start the ring service", e)
            false
        }

        /** Flutter is up and ringing itself: stop here, keep the notification. */
        fun handOff() = runOnMain { instance?.finish(removeNotification = false, missed = false) }

        /** Answered or declined from the notification. */
        fun stop() = runOnMain { instance?.finish(removeNotification = true, missed = false) }

        private fun runOnMain(block: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) block()
            else Handler(Looper.getMainLooper()).post(block)
        }
    }
}

