package com.tbtrapp.audio

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import com.tbtrapp.calls.CallNotifications

/**
 * Foreground wrapper around VoiceRecorder so recording survives the app
 * being backgrounded, and keeps running through network drops — recording
 * itself is local (no network needed to capture), so a network loss never
 * stops it; the callback below just logs/updates the notification.
 */
class VoiceRecordingService : Service() {

    companion object {
        private const val TAG = "VoiceRecordingService"
        const val ACTION_START = "com.tbtrapp.audio.action.START"
        const val ACTION_STOP = "com.tbtrapp.audio.action.STOP"
        const val ACTION_CANCEL = "com.tbtrapp.audio.action.CANCEL"

        fun start(context: Context) {
            val intent = Intent(context, VoiceRecordingService::class.java).setAction(ACTION_START)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, VoiceRecordingService::class.java).setAction(ACTION_STOP))
        }

        fun cancel(context: Context) {
            context.startService(Intent(context, VoiceRecordingService::class.java).setAction(ACTION_CANCEL))
        }
    }

    interface RecordingListener {
        fun onRecordingStopped(base64Audio: String, durationSeconds: Int)
        fun onRecordingFailed(error: Exception)
    }

    inner class LocalBinder : Binder() {
        fun getService(): VoiceRecordingService = this@VoiceRecordingService
    }
    private val binder = LocalBinder()

    private var listener: RecordingListener? = null
    fun setListener(l: RecordingListener?) { listener = l }

    private lateinit var recorder: VoiceRecorder
    @Volatile private var isRecording = false

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        CallNotifications.createChannels(this)
        recorder = VoiceRecorder(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                if (isRecording) return START_NOT_STICKY
                startForegroundTyped()
                registerNetworkCallback()
                try {
                    recorder.startRecording()
                    isRecording = true
                } catch (e: Exception) {
                    Log.e(TAG, "startRecording failed: ${e.message}", e)
                    listener?.onRecordingFailed(e)
                    stopSelfSafely()
                }
            }
            ACTION_STOP -> {
                finishRecording()
            }
            ACTION_CANCEL -> {
                try { recorder.cancelRecording() } catch (_: Exception) {}
                isRecording = false
                stopSelfSafely()
            }
        }
        return START_NOT_STICKY
    }

    private fun startForegroundTyped() {
        val stopIntent = Intent(this, VoiceRecordingService::class.java).setAction(ACTION_STOP)
        val stopPending = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = CallNotifications.buildRecordingNotification(this, stopPending)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                CallNotifications.NOTIF_ID_RECORDING, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(CallNotifications.NOTIF_ID_RECORDING, notification)
        }
    }

    private fun registerNetworkCallback() {
        connectivityManager = getSystemService(ConnectivityManager::class.java)
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.d(TAG, "Network back during recording — no action needed, capture is local")
            }
            override fun onLost(network: Network) {
                Log.w(TAG, "Network lost during recording — recording continues unaffected")
            }
        }
        networkCallback = callback
        connectivityManager?.registerNetworkCallback(request, callback)
    }

    private fun finishRecording() {
        if (!isRecording) return
        val durationSeconds = try {
            recorder.stopRecording()
        } catch (e: Exception) {
            listener?.onRecordingFailed(e)
            isRecording = false
            stopSelfSafely()
            return
        }
        isRecording = false

        recorder.encodeRecordingToBase64(
            onSuccess = { base64 ->
                listener?.onRecordingStopped(base64, durationSeconds)
                stopSelfSafely()
            },
            onFailure = { e ->
                listener?.onRecordingFailed(e)
                stopSelfSafely()
            }
        )
    }

    private fun stopSelfSafely() {
        try {
            networkCallback?.let { connectivityManager?.unregisterNetworkCallback(it) }
        } catch (_: Exception) {}
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (isRecording) {
            try { recorder.cancelRecording() } catch (_: Exception) {}
        }
        super.onDestroy()
    }
}