package com.tbtrapp.calls

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Bridges call notification action buttons to the call services via a
 * broadcast instead of a direct `PendingIntent.getService`.
 *
 * The ringing notification ([CallService]) currently targets the service
 * directly, but the in-call notification's "End call" action and any external
 * "hang up" trigger route through here so there's a single, always-registered
 * receiver that works even when starting a service straight from a background
 * PendingIntent would be restricted.
 */
class CallActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val callId = intent.getStringExtra(EXTRA_CALL_ID)
        Log.d(TAG, "action=${intent.action} callId=$callId")

        when (intent.action) {
            ACTION_ACCEPT -> forwardToCallService(context, CallService.ACTION_ACCEPT_CALL, callId)
            ACTION_DECLINE -> forwardToCallService(context, CallService.ACTION_DECLINE_CALL, callId)
            ACTION_END -> {
                forwardToCallService(context, CallService.ACTION_END_CALL, callId)
                runCatching {
                    ContextCompat.startForegroundService(
                        context, OngoingCallService.buildEndIntent(context)
                    )
                }
            }
        }
    }

    private fun forwardToCallService(context: Context, serviceAction: String, callId: String?) {
        val intent = Intent(context, CallService::class.java).apply {
            action = serviceAction
            if (callId != null) putExtra(CallService.EXTRA_CALL_ID, callId)
        }
        runCatching { ContextCompat.startForegroundService(context, intent) }
    }

    companion object {
        private const val TAG = "CallActionReceiver"

        const val ACTION_ACCEPT = "com.tbtrapp.calls.action.RECV_ACCEPT"
        const val ACTION_DECLINE = "com.tbtrapp.calls.action.RECV_DECLINE"
        const val ACTION_END = "com.tbtrapp.calls.action.RECV_END"

        const val EXTRA_CALL_ID = "call_id"
    }
}
