package com.tbtrapp.calls

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.database.FirebaseDatabase

/**
 * Handles the "Decline" action on the full-screen incoming-call notification
 * that [CallNotificationServiceExtension] posts from a background / killed
 * state.
 *
 * It cancels the notification immediately and writes
 * `calls/{callId}/state = "DECLINED"` straight to Realtime Database with the
 * native Firebase SDK, so the caller stops ringing right away instead of
 * waiting out its 45 s no-answer timeout. `goAsync()` keeps the process
 * alive long enough for that write to flush.
 */
class CallDeclineReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_DECLINE) return
        val callId = intent.getStringExtra("callId").orEmpty()

        NotificationManagerCompat.from(context)
            .cancel(CallNotificationServiceExtension.INCOMING_CALL_NOTIF_ID)

        if (callId.isBlank()) return

        val pending = goAsync()
        try {
            FirebaseDatabase.getInstance()
                .getReference("calls")
                .child(callId)
                .child("state")
                .setValue("DECLINED")
                .addOnCompleteListener {
                    Log.d(TAG, "decline written for $callId (ok=${it.isSuccessful})")
                    pending.finish()
                }
        } catch (e: Exception) {
            Log.e(TAG, "decline write failed for $callId", e)
            pending.finish()
        }
    }

    companion object {
        private const val TAG = "CallDeclineReceiver"
        const val ACTION_DECLINE = "com.tbtrapp.calls.action.FS_DECLINE"
    }
}
