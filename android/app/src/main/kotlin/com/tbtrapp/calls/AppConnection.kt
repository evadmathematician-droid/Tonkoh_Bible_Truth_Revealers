package com.tbtrapp.calls

import android.content.Context
import android.content.Intent
import android.telecom.Connection
import android.telecom.DisconnectCause
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * The app's [Connection] for a single self-managed call, built by
 * [CallConnectionService].
 *
 * It bridges Telecom-driven actions — the user answering / rejecting / hanging
 * up from the system call UI, a Bluetooth headset button, Android Auto, or the
 * OS ending the call because another call took over — onto the app's own
 * services ([CallService] while ringing, [OngoingCallService] once connected).
 *
 * App-driven state changes flow the other way and don't come through here:
 * they go straight to [CallConnectionRegistry] (`markActive`, `disconnect`).
 */
class AppConnection(private val callType: String) : Connection() {

    private var callId: String = ""

    /** Called right after construction by [CallConnectionService]. */
    fun bindCallId(id: String) {
        callId = id
        setExtras(android.os.Bundle().apply {
            putString(TelecomCallManager.EXTRA_CALL_ID, id)
            putString(TelecomCallManager.EXTRA_CALL_TYPE, callType)
        })
    }

    private val context: Context?
        get() = if (CallAppContextProvider.isReady) CallAppContextProvider.appContext else null

    // ── Telecom → app ──────────────────────────────────────────────────────

    override fun onAnswer() {
        Log.d(TAG, "onAnswer($callId)")
        sendToCallService(CallService.ACTION_ACCEPT_CALL)
    }

    override fun onReject() {
        Log.d(TAG, "onReject($callId)")
        sendToCallService(CallService.ACTION_DECLINE_CALL)
        finish(DisconnectCause.REJECTED)
    }

    override fun onDisconnect() {
        Log.d(TAG, "onDisconnect($callId)")
        endCallEverywhere()
        finish(DisconnectCause.LOCAL)
    }

    override fun onAbort() {
        Log.d(TAG, "onAbort($callId)")
        endCallEverywhere()
        finish(DisconnectCause.CANCELED)
    }

    override fun onHold() {
        setOnHold()
    }

    override fun onUnhold() {
        setActive()
    }

    /**
     * Self-managed apps must show their own incoming-call UI here. The eager
     * path in [CallConnectionService.onCreateIncomingConnection] already starts
     * [CallService] (which posts the full-screen notification and launches
     * [IncomingCallActivity]); [CallService] de-dupes on the call id, so
     * re-sending the intent here is a harmless safety net.
     */
    override fun onShowIncomingCallUi() {
        Log.d(TAG, "onShowIncomingCallUi($callId)")
        val ctx = context ?: return
        val intent = Intent(ctx, CallService::class.java).apply {
            action = CallService.ACTION_INCOMING_CALL
            putExtra(CallService.EXTRA_CALL_ID, callId)
            putExtra(CallService.EXTRA_CALL_TYPE, callType)
        }
        runCatching { ContextCompat.startForegroundService(ctx, intent) }
    }

    // ── helpers ────────────────────────────────────────────────────────────

    private fun sendToCallService(action: String) {
        val ctx = context ?: return
        val intent = Intent(ctx, CallService::class.java).apply {
            this.action = action
            putExtra(CallService.EXTRA_CALL_ID, callId)
        }
        runCatching { ContextCompat.startForegroundService(ctx, intent) }
    }

    private fun endCallEverywhere() {
        val ctx = context ?: return
        runCatching {
            ContextCompat.startForegroundService(
                ctx,
                Intent(ctx, CallService::class.java).apply {
                    action = CallService.ACTION_END_CALL
                    putExtra(CallService.EXTRA_CALL_ID, callId)
                }
            )
        }
        runCatching { ctx.startService(OngoingCallService.buildEndIntent(ctx)) }
    }

    private fun finish(cause: Int) {
        setDisconnected(DisconnectCause(cause))
        destroy()
        if (callId.isNotBlank()) CallConnectionRegistry.remove(callId)
    }

    companion object {
        private const val TAG = "AppConnection"
    }
}
