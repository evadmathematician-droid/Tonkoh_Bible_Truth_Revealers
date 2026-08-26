package com.tbtrapp.calls

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.CountDownTimer
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.telecom.DisconnectCause
import androidx.core.app.NotificationCompat
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener

class CallService : Service() {

    companion object {
        const val ACTION_INCOMING_CALL = "com.tbtrapp.calls.action.INCOMING_CALL"
        const val ACTION_ACCEPT_CALL = "com.tbtrapp.calls.action.ACCEPT_CALL"
        const val ACTION_DECLINE_CALL = "com.tbtrapp.calls.action.DECLINE_CALL"
        const val ACTION_END_CALL = "com.tbtrapp.calls.action.END_CALL"

        const val EXTRA_CALL_ID = "extra_call_id"
        const val EXTRA_CALLER_ID = "extra_caller_id"
        const val EXTRA_CALLER_NAME = "extra_caller_name"
        const val EXTRA_CALLER_PHOTO = "extra_caller_photo"
        const val EXTRA_CHAT_ID = "extra_chat_id"
        const val EXTRA_CALL_TYPE = "extra_call_type"

        private const val EXTRA_CALL_ID_FROM_ACTIVITY = "call_id"

        private const val CHANNEL_ID = "tbtr_incoming_calls"
        private const val NOTIFICATION_ID = 5501
        private const val RING_TIMEOUT_MS = 45_000L
    }

    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var timeoutTimer: CountDownTimer? = null
    private var stateListener: ValueEventListener? = null

    private var currentCallId: String? = null
    private var currentCallerId: String = ""
    private var currentCallerName: String = "Unknown"
    private var currentCallerPhoto: String = ""
    private var currentChatId: String = ""
    private var currentCallType: String = "audio"

    private val isVideoCall: Boolean
        get() = currentCallType.equals("video", ignoreCase = true)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_INCOMING_CALL -> handleIncomingCall(intent)
            ACTION_ACCEPT_CALL -> handleAccept(intent)
            ACTION_DECLINE_CALL -> handleDecline(intent)
            ACTION_END_CALL -> handleEndCall(intent)
            else -> {
                android.util.Log.w("CallService", "Unknown action: ${intent?.action}")
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun getCallId(intent: Intent?): String? {
        return intent?.getStringExtra(EXTRA_CALL_ID)
            ?: intent?.getStringExtra(EXTRA_CALL_ID_FROM_ACTIVITY)
            ?: intent?.getStringExtra("callId")
            ?: currentCallId
    }

    private fun handleIncomingCall(intent: Intent) {
        val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return stopSelf()
        currentCallId = callId
        currentCallerId = intent.getStringExtra(EXTRA_CALLER_ID) ?: ""
        currentCallerName = intent.getStringExtra(EXTRA_CALLER_NAME) ?: "Unknown"
        currentCallerPhoto = intent.getStringExtra(EXTRA_CALLER_PHOTO) ?: ""
        currentChatId = intent.getStringExtra(EXTRA_CHAT_ID) ?: ""
        currentCallType = intent.getStringExtra(EXTRA_CALL_TYPE) ?: "audio"

        android.util.Log.d("CallDebug", "CallService.handleIncomingCall: currentCallType='$currentCallType' isVideoCall=$isVideoCall")

        createNotificationChannel()

        // FIX: startForeground() must be called synchronously and FIRST, before
        // anything else in this method. Now that we're started from
        // CallConnectionService.onCreateIncomingConnection() (Telecom callback),
        // this call carries Telecom's background-start exemption and will not
        // throw SecurityException, even from a cold/killed process.
        if (!startForegroundForCurrentCallType(callId)) {
            android.util.Log.e("CallService", "startForeground failed — stopping to avoid a stuck/crashed ringing state")
            clearCallState()
            stopSelf()
            return
        }

        startRingtoneAndVibration()
        watchForRemoteStateChange(callId)
        startTimeoutTimer(callId)

        try {
            startActivity(buildCallActivityIntent(callId))
        } catch (e: Exception) {
            android.util.Log.e("CallService", "Direct launch failed, relying on notification: ${e.message}")
        }
    }

    /**
     * Requests phoneCall + microphone (+camera for video). Now legitimate since
     * this app is registered as a self-managed Telecom ConnectionService — see
     * CallConnectionService / TelecomCallManager. Requesting phoneCall without
     * that registration is what threw SecurityException before; that's fixed now.
     *
     * Returns true if the foreground promotion succeeded.
     */
    private fun startForegroundForCurrentCallType(callId: String): Boolean {
        val notification = buildRingingNotification(callId)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (isVideoCall) serviceType = serviceType or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                startForeground(NOTIFICATION_ID, notification, serviceType)
            } else {
                @Suppress("DEPRECATION")
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: SecurityException) {
            android.util.Log.e("CallService", "startForeground SecurityException: ${e.message}", e)
            false
        } catch (e: Exception) {
            android.util.Log.e("CallService", "startForeground failed: ${e.message}", e)
            false
        }
    }

    private fun buildCallActivityIntent(callId: String) =
        IncomingCallActivity.buildIntent(
            this, callId, currentCallerId, currentCallerName,
            currentCallerPhoto, currentChatId, currentCallType
        )

    private fun buildRingingNotification(callId: String): android.app.Notification {
        val fullScreenPendingIntent = PendingIntent.getActivity(
            this, 0, buildCallActivityIntent(callId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val declineIntent = Intent(this, CallService::class.java).apply {
            action = ACTION_DECLINE_CALL
            putExtra(EXTRA_CALL_ID, callId)
        }
        val declinePendingIntent = PendingIntent.getService(
            this, 1, declineIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val acceptIntent = Intent(this, CallService::class.java).apply {
            action = ACTION_ACCEPT_CALL
            putExtra(EXTRA_CALL_ID, callId)
        }
        val acceptPendingIntent = PendingIntent.getService(
            this, 2, acceptIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle(if (isVideoCall) "Incoming video call" else "Incoming call")
            .setContentText(currentCallerName)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Decline", declinePendingIntent)
            .addAction(android.R.drawable.sym_action_call, "Accept", acceptPendingIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(CHANNEL_ID, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Ringing screen for incoming TBTR calls"
                    setSound(null, null)
                    enableVibration(false)
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    // FIX: RingtoneManager.getActualDefaultRingtoneUri() is the exact call that
    // threw SecurityException("...was not granted this permission: WRITE_SETTINGS")
    // on the affected (Transsion/Infinix XOS) ROMs — see CallNotifications.kt for
    // the full explanation. It was already fixed there for the (unused) MAX-
    // importance channel, but this is the actual method that plays the ringtone
    // for real incoming calls, and it still had the crashing call. The try/catch
    // below meant it never crashed the service, but it did mean the ringtone
    // silently failed to play on those devices — a real but easy-to-miss bug,
    // since vibration (below) kept working and masked it.
    //
    // Settings.System.DEFAULT_RINGTONE_URI is a static content URI reference —
    // a pure read with no vendor-side write-back — and is what this resolves to
    // on stock AOSP anyway, so behavior is unchanged everywhere else.
    private fun startRingtoneAndVibration() {
        try {
            val uri = try {
                Settings.System.DEFAULT_RINGTONE_URI
            } catch (e: SecurityException) {
                android.util.Log.w("CallService", "Ringtone URI lookup failed, falling back", e)
                Settings.System.DEFAULT_NOTIFICATION_URI
            }
            ringtone = RingtoneManager.getRingtone(this, uri).apply {
                audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                play()
            }
        } catch (e: Exception) {
            android.util.Log.e("CallService", "Ringtone failed: ${e.message}")
        }

        vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        val pattern = longArrayOf(0, 800, 800)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
        } else {
            @Suppress("DEPRECATION")
            vibrator?.vibrate(pattern, 0)
        }
    }

    private fun stopRingtoneAndVibration() {
        try { ringtone?.stop() } catch (_: Exception) {}
        ringtone = null
        vibrator?.cancel()
        vibrator = null
    }

    private fun watchForRemoteStateChange(callId: String) {
        val ref = FirebaseDatabase.getInstance().getReference("calls").child(callId).child("state")
        val listener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val state = snapshot.getValue(String::class.java) ?: return
                if (currentCallId == callId && (state == "ENDED" || state == "CANCELLED")) {
                    endCall()
                }
            }
            override fun onCancelled(error: DatabaseError) {}
        }
        ref.addValueEventListener(listener)
        stateListener = listener
    }

    private fun startTimeoutTimer(callId: String) {
        timeoutTimer?.cancel()
        timeoutTimer = object : CountDownTimer(RING_TIMEOUT_MS, RING_TIMEOUT_MS) {
            override fun onTick(millisUntilFinished: Long) {}
            override fun onFinish() {
                if (currentCallId == callId) handleDecline(null, "MISSED")
            }
        }.start()
    }

    private fun handleAccept(intent: Intent?) {
        val callId = getCallId(intent) ?: return stopSelf()
        FirebaseDatabase.getInstance().getReference("calls").child(callId).child("state").setValue("ACCEPTED")
        CallConnectionRegistry.markActive(callId) // keep Telecom's Connection state in sync
        stopRingtoneAndVibration()
        timeoutTimer?.cancel()

        startForegroundService(
            OngoingCallService.buildStartIntent(this, callId, isCaller = false, callType = currentCallType, peerName = currentCallerName)
        )

        val launchedFromActivity = intent?.hasExtra(EXTRA_CALL_ID_FROM_ACTIVITY) == true
        if (!launchedFromActivity) {
            startActivity(OngoingCallActivity.buildIntent(this, callId, currentCallType, isCaller = false))
        }

        clearCallState()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun handleDecline(intent: Intent?, reason: String = "DECLINED") {
        val callId = getCallId(intent) ?: return stopSelf()
        FirebaseDatabase.getInstance().getReference("calls").child(callId).child("state").setValue(reason)
        CallConnectionRegistry.disconnect(
            callId,
            if (reason == "MISSED") DisconnectCause.MISSED else DisconnectCause.REJECTED
        )
        endCall()
    }

    private fun handleEndCall(intent: Intent?) {
        val callId = getCallId(intent) ?: return stopSelf()
        FirebaseDatabase.getInstance().getReference("calls").child(callId).child("state").setValue("ENDED")
        CallConnectionRegistry.disconnect(callId, DisconnectCause.LOCAL)
        endCall()
    }

    private fun endCall() {
        stopRingtoneAndVibration()
        timeoutTimer?.cancel()
        clearCallState()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun clearCallState() {
        currentCallId?.let { id ->
            stateListener?.let { l ->
                FirebaseDatabase.getInstance().getReference("calls").child(id).child("state").removeEventListener(l)
            }
        }
        stateListener = null
        currentCallId = null
    }

    override fun onDestroy() {
        stopRingtoneAndVibration()
        timeoutTimer?.cancel()
        super.onDestroy()
    }
}