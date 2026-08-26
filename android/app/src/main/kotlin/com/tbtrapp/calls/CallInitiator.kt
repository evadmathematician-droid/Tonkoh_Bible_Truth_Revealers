package com.tbtrapp.calls

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.tbtrapp.call.CallSession
import com.tbtrapp.call.CallState
import com.tbtrapp.call.FirebaseSignalingRepository

class CallInitiator(
    private val context: Context,
    private val signaling: FirebaseSignalingRepository = FirebaseSignalingRepository()
) {
    /**
     * Call this the moment the user taps "call" — starts the foreground
     * service immediately after the call row is created, before any UI
     * for the call screen exists.
     */
    fun sendCall(session: CallSession, callType: String, peerName: String) {
        signaling.createCall(session) { callId ->
            signaling.setState(callId, CallState.RINGING)

            val cameraGranted = callType.equals("video", true) &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                    PackageManager.PERMISSION_GRANTED

            val startIntent = OngoingCallService.buildStartIntent(
                context, callId, isCaller = true, callType, peerName, cameraGranted
            )
            ContextCompat.startForegroundService(context, startIntent)

            context.startActivity(
                OngoingCallActivity.buildIntent(context, callId, callType, isCaller = true, peerName)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }
}