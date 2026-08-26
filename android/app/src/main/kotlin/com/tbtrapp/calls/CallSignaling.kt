package com.tbtrapp.calls

import android.content.Context
import com.google.firebase.database.FirebaseDatabase
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.RequestBody.Companion.toRequestBody

private const val PUSH_RELAY_URL = "https://small-dream-b231.tonkohbibletruthrevealers.workers.dev/send-call-push"
private const val PUSH_RELAY_SECRET = "test-relay-secret-123"

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
            trySendCallPush(calleeUid, callerName, callMap)
        }
        .addOnFailureListener {
            android.util.Log.e("CallSignaling", "Failed to write call to RTDB", it)
        }
}

private fun trySendCallPush(
    calleeUid: String,
    callerName: String,
    callData: Map<String, Any?>
) {
    FirebaseDatabase.getInstance()
        .getReference("users")
        .child(calleeUid)
        .child("oneSignalId")
        .get()
        .addOnSuccessListener { snapshot ->
            val subId = snapshot.getValue(String::class.java)
            if (subId.isNullOrBlank()) {
                android.util.Log.w("CallSignaling", "No OneSignal ID — relying on Firebase RTDB only")
                return@addOnSuccessListener
            }

            val jsonBody = org.json.JSONObject().apply {
                put("secret", PUSH_RELAY_SECRET)
                put("oneSignalId", subId)
                put("callId", callData["callId"])
                put("callerId", callData["callerId"])
                put("callerName", callerName)
                put("callerPhoto", callData["callerPhoto"])
                put("callType", callData["type"])
                put("chatId", callData["chatId"])
            }.toString()

            val request = okhttp3.Request.Builder()
                .url(PUSH_RELAY_URL)
                .addHeader("Content-Type", "application/json; charset=utf-8")
                .post(jsonBody.toRequestBody("application/json".toMediaTypeOrNull()))
                .build()

            okhttp3.OkHttpClient().newCall(request).enqueue(object : okhttp3.Callback {
                override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
                    android.util.Log.w("CallSignaling", "Push relay failed (network): ${e.message}")
                }
                override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                    if (!response.isSuccessful) {
                        android.util.Log.w("CallSignaling", "Push relay HTTP ${response.code}")
                    } else {
                        android.util.Log.d("CallSignaling", "Push relay call OK")
                    }
                    response.close()
                }
            })
        }
        .addOnFailureListener {
            android.util.Log.e("CallSignaling", "Failed to read callee OneSignal ID", it)
        }
}