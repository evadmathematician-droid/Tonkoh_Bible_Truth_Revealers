package com.tbtrapp

import android.content.Intent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.tbtrapp.calls.CallForegroundService
import com.tbtrapp.platform.RingtonePlayer
import com.tbtrapp.platform.SimContactsReader
import com.tbtrapp.share.ShareInbox

// AudioServiceActivity extends FlutterActivity — required by audio_service so
// the media-playback foreground service can bind to a running activity.
class MainActivity : AudioServiceActivity() {

    private val ringtoneChannel = "com.tbtrapp/ringtone"
    private val simContactsChannel = "com.tbtrapp/sim_contacts"
    private val callsChannel = "com.tbtrapp/calls"

    private val shareChannel = "com.tbtrapp/share"

    private var ringtonePlayer: RingtonePlayer? = null
    private var callsMethodChannel: MethodChannel? = null
    private var shareMethodChannel: MethodChannel? = null

    // Call extras from the launch intent (full-screen incoming-call
    // notification opened from a cold start), handed to Flutter when it asks
    // via `getInitialCallExtras`.
    private var pendingCallExtras: Map<String, String?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        ringtonePlayer = RingtonePlayer(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ringtoneChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRingtone" -> {
                        ringtonePlayer?.start()
                        result.success(true)
                    }
                    "stopRingtone" -> {
                        ringtonePlayer?.stop()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, simContactsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSimContacts" -> {
                        try {
                            result.success(SimContactsReader(applicationContext).readAll())
                        } catch (e: Exception) {
                            result.error("sim_read_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        callsMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, callsChannel,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialCallExtras" -> {
                        result.success(pendingCallExtras)
                        pendingCallExtras = null
                    }
                    "startCallForeground" -> {
                        try {
                            CallForegroundService.start(
                                applicationContext,
                                call.argument<String>("callType") ?: "audio",
                                call.argument<String>("peerName") ?: "",
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("fgs_start_failed", e.message, null)
                        }
                    }
                    "stopCallForeground" -> {
                        CallForegroundService.stop(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // Content shared in from other apps (ShareReceiverActivity → ShareInbox).
        // Dart calls "ready" once its handler is registered: that returns any
        // share that arrived before Flutter was up, and from then on new
        // shares are pushed as "onShare".
        shareMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, shareChannel,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> {
                        ShareInbox.setListener { payload ->
                            shareMethodChannel?.invokeMethod("onShare", payload.toMap())
                        }
                        result.success(ShareInbox.take()?.toMap())
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // Launch intent may already carry call extras (cold start from the
        // full-screen notification).
        extractCallExtras(intent)?.let { pendingCallExtras = it }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractCallExtras(intent)?.let { extras ->
            val channel = callsMethodChannel
            if (channel != null) {
                channel.invokeMethod("onCallIntent", extras)
            } else {
                pendingCallExtras = extras
            }
        }
    }

    override fun onResume() {
        super.onResume()
        isForeground = true
    }

    override fun onPause() {
        super.onPause()
        isForeground = false
    }

    override fun onDestroy() {
        // Never let a ring outlive the activity.
        ringtonePlayer?.stop()
        ringtonePlayer = null
        callsMethodChannel = null
        ShareInbox.setListener(null)
        shareMethodChannel = null
        super.onDestroy()
    }

    private fun extractCallExtras(intent: Intent?): Map<String, String?>? {
        val action = intent?.getStringExtra("callAction") ?: return null
        val callId = intent.getStringExtra("callId") ?: return null
        if (callId.isBlank()) return null
        return mapOf(
            "callAction" to action,
            "callId" to callId,
            "callerId" to intent.getStringExtra("callerId"),
            "callerName" to intent.getStringExtra("callerName"),
            "callerPhoto" to intent.getStringExtra("callerPhoto"),
            "chatId" to intent.getStringExtra("chatId"),
            "callType" to intent.getStringExtra("callType"),
        )
    }

    companion object {
        /** Read by CallNotificationServiceExtension to decide whether the
         *  in-app RTDB path is already handling an incoming call. */
        @Volatile
        var isForeground: Boolean = false
    }
}
