package com.tbtrapp.calls

import android.content.Intent
import android.net.Uri
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import androidx.core.content.ContextCompat

class CallConnectionService : ConnectionService() {

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest
    ): Connection {
        val extras = request.extras
        val callId = extras.getString(TelecomCallManager.EXTRA_CALL_ID) ?: ""
        val callerId = extras.getString(TelecomCallManager.EXTRA_CALLER_ID) ?: ""
        val callerName = extras.getString(TelecomCallManager.EXTRA_CALLER_NAME) ?: "Unknown"
        val callerPhoto = extras.getString(TelecomCallManager.EXTRA_CALLER_PHOTO) ?: ""
        val chatId = extras.getString(TelecomCallManager.EXTRA_CHAT_ID) ?: ""
        val callType = extras.getString(TelecomCallManager.EXTRA_CALL_TYPE) ?: "audio"

        val connection = buildConnection(callerId, callerName, callType).apply {
            bindCallId(callId)
            setRinging()
        }
        if (callId.isNotBlank()) CallConnectionRegistry.put(callId, connection)

        // This is the whole point: we're inside a Telecom-driven callback, which
        // carries the background-foreground-service-start exemption. This will NOT
        // throw SecurityException even from a cold, fully-killed process — unlike
        // the old direct push -> startForegroundService path.
        val serviceIntent = Intent(this, CallService::class.java).apply {
            action = CallService.ACTION_INCOMING_CALL
            putExtra(CallService.EXTRA_CALL_ID, callId)
            putExtra(CallService.EXTRA_CALLER_ID, callerId)
            putExtra(CallService.EXTRA_CALLER_NAME, callerName)
            putExtra(CallService.EXTRA_CALLER_PHOTO, callerPhoto)
            putExtra(CallService.EXTRA_CHAT_ID, chatId)
            putExtra(CallService.EXTRA_CALL_TYPE, callType)
        }
        ContextCompat.startForegroundService(this, serviceIntent)

        return connection
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest
    ) {
        super.onCreateIncomingConnectionFailed(connectionManagerPhoneAccount, request)
        android.util.Log.e("CallConnectionService", "Incoming connection failed — check that the calling account is enabled in system Settings")
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest
    ): Connection {
        val extras = request.extras.getBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS) ?: request.extras
        val callId = extras.getString(TelecomCallManager.EXTRA_CALL_ID) ?: ""
        val callType = extras.getString(TelecomCallManager.EXTRA_CALL_TYPE) ?: "audio"

        val connection = buildConnection("", "", callType).apply {
            bindCallId(callId)
            setDialing()
            setActive()
        }
        if (callId.isNotBlank()) CallConnectionRegistry.put(callId, connection)
        return connection
    }

    private fun buildConnection(calleeAddress: String, callerName: String, callType: String): AppConnection {
        val isVideo = callType.equals("video", ignoreCase = true)
        return AppConnection(callType).apply {
            setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
            setAddress(Uri.fromParts("tel", calleeAddress, null), TelecomManager.PRESENTATION_ALLOWED)
            connectionProperties = Connection.PROPERTY_SELF_MANAGED
            connectionCapabilities = Connection.CAPABILITY_SUPPORT_HOLD or Connection.CAPABILITY_MUTE or
                    (if (isVideo) Connection.CAPABILITY_CAN_UPGRADE_TO_VIDEO else 0)
            audioModeIsVoip = true
            videoState = if (isVideo) VideoProfile.STATE_BIDIRECTIONAL else VideoProfile.STATE_AUDIO_ONLY
        }
    }
}