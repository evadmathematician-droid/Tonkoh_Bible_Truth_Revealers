package com.tbtrapp.calls

import android.content.Context
import com.google.firebase.database.FirebaseDatabase

// Not called today — calls are started from Dart (lib/calls/call_initiator.dart),
// which also sends the call push through the Worker with the user's Firebase
// ID token. The native push copy that lived here shipped the Worker's shared
// secret, so it was removed; if this entry point is ever wired up again, send
// the push from the Dart side.
fun initiateCall(
    context: Context,
    callerUid: String,
    callerName: String,
    callerPhoto: String = "",
    calleeUid: String,
    chatId: String,
    callType: String,
    onCallIdReady: (String) -> Unit
) {
    val callsRef = FirebaseDatabase.getInstance().getReference("calls").push()
    val callId = callsRef.key ?: return

    val callMap = mapOf(
        "callId" to callId,
        "callerId" to callerUid,
        "callerName" to callerName,
        "callerPhoto" to callerPhoto,
        "calleeId" to calleeUid,
        "chatId" to chatId,
        "type" to callType,
        "state" to "RINGING",
        "createdAt" to System.currentTimeMillis()
    )

    callsRef.setValue(callMap)
        .addOnSuccessListener {
            android.util.Log.d("CallSignaling", "Call doc created: $callId")

            // Hand the call to Telecom/our self-managed account so the system
            // treats it like a real call (audio focus/routing, other-call
            // handling, call log, etc.) instead of just a Firebase record.
            // This triggers CallConnectionService.onCreateOutgoingConnection().
            // Never touches the SIM — self-managed accounts don't route
            // through the carrier regardless.
            TelecomCallManager.placeOutgoingCall(
                context = context,
                callId = callId,
                calleeId = calleeUid,
                callType = callType
            )

            onCallIdReady(callId)
        }
        .addOnFailureListener {
            android.util.Log.e("CallSignaling", "Failed to write call to RTDB", it)
        }
}
