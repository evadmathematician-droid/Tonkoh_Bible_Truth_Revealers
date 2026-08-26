package com.tbtrapp.calls

import android.content.Intent
import android.telecom.Connection
import android.telecom.DisconnectCause
import com.google.firebase.database.FirebaseDatabase

class AppConnection(private val callType: String) : Connection() {

    var callId: String? = null
        private set

    fun bindCallId(id: String) { callId = id }

    // Fires if the user answers via Telecom's own surfaces (Bluetooth headset
    // button, Android Auto, wearable, etc.) rather than your notification.
    override fun onAnswer() {
        setActive()
        val id = callId ?: return
        val context = CallAppContext.context
        FirebaseDatabase.getInstance().getReference("calls").child(id).child("state").setValue("ACCEPTED")
        context.startService(Intent(context, CallService::class.java).apply {
            action = CallService.ACTION_ACCEPT_CALL
            putExtra(CallService.EXTRA_CALL_ID, id)
        })
    }

    override fun onReject() {
        val id = callId
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
        if (id != null) {
            val context = CallAppContext.context
            FirebaseDatabase.getInstance().getReference("calls").child(id).child("state").setValue("DECLINED")
            context.startService(Intent(context, CallService::class.java).apply {
                action = CallService.ACTION_DECLINE_CALL
                putExtra(CallService.EXTRA_CALL_ID, id)
            })
            CallConnectionRegistry.remove(id)
        }
    }

    override fun onDisconnect() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
        callId?.let { CallConnectionRegistry.remove(it) }
    }

    override fun onAbort() {
        setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
        destroy()
        callId?.let { CallConnectionRegistry.remove(it) }
    }

    // Self-managed apps MUST supply their own incoming-call UI here.
    // CallConnectionService already kicks off CallService (ringing
    // notification / full-screen IncomingCallActivity) right after
    // creating this Connection, so there's nothing further to do.
    override fun onShowIncomingCallUi() {}
}