package com.tbtrapp.calls

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.database.FirebaseDatabase

class CallActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_ACCEPT = "com.tbtrapp.calls.action.ACCEPT"
        const val ACTION_DECLINE = "com.tbtrapp.calls.action.DECLINE"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val callId = intent.getStringExtra("call_id") ?: return

        when (intent.action) {
            ACTION_ACCEPT -> {
                val callType = intent.getStringExtra("call_type") ?: "audio"
                val peerName = intent.getStringExtra("peer_name") ?: "Unknown"

                NotificationManagerCompat.from(context).cancel(callId.hashCode())

                val cameraGranted = callType.equals("video", true) &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                        PackageManager.PERMISSION_GRANTED

                // Foreground service starts immediately — no Activity required.
                val startIntent = OngoingCallService.buildStartIntent(
                    context, callId, isCaller = false, callType, peerName, cameraGranted
                )
                ContextCompat.startForegroundService(context, startIntent)

                FirebaseDatabase.getInstance().getReference("calls").child(callId)
                    .child("state").setValue("ACTIVE")

                // Only need the Activity to prompt for CAMERA permission if we don't have it yet.
                // Otherwise the call is fully live in the background already.
                if (callType.equals("video", true) && !cameraGranted) {
                    context.startActivity(
                        OngoingCallActivity.buildIntent(context, callId, callType, isCaller = false, peerName)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                }
            }
            ACTION_DECLINE -> {
                NotificationManagerCompat.from(context).cancel(callId.hashCode())
                FirebaseDatabase.getInstance().getReference("calls").child(callId)
                    .child("state").setValue("DECLINED")
            }
        }
    }
}