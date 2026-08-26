package com.tbtrapp.calls

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener

class IncomingCallActivity : ComponentActivity() {

    companion object {
        private const val EXTRA_CALL_ID = "call_id"
        private const val EXTRA_CALLER_ID = "caller_id"
        private const val EXTRA_CALLER_NAME = "caller_name"
        private const val EXTRA_CALLER_PHOTO = "caller_photo"
        private const val EXTRA_CHAT_ID = "chat_id"
        private const val EXTRA_CALL_TYPE = "call_type"

        fun buildIntent(
            context: Context,
            callId: String,
            callerId: String,
            callerName: String,
            callerPhoto: String,
            chatId: String,
            callType: String
        ): Intent = Intent(context, IncomingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_CALL_ID, callId)
            putExtra(EXTRA_CALLER_ID, callerId)
            putExtra(EXTRA_CALLER_NAME, callerName)
            putExtra(EXTRA_CALLER_PHOTO, callerPhoto)
            putExtra(EXTRA_CHAT_ID, chatId)
            putExtra(EXTRA_CALL_TYPE, callType)
        }
    }

    private var stateListener: ValueEventListener? = null
    @Volatile private var hasAccepted = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                        WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }

        val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return finish()
        val callerName = intent.getStringExtra(EXTRA_CALLER_NAME) ?: "Unknown"
        val callerPhoto = intent.getStringExtra(EXTRA_CALLER_PHOTO) ?: ""
        val callType = intent.getStringExtra(EXTRA_CALL_TYPE) ?: "audio"

        android.util.Log.d("CallDebug", "IncomingCallActivity received callId=$callId callType='$callType'")

        val isVideoCall = callType.equals("video", ignoreCase = true)

        setContent {
            MaterialTheme {
                IncomingCallScreen(
                    callId = callId,
                    callerName = callerName,
                    callerPhotoBase64 = callerPhoto,
                    isVideoCall = isVideoCall,
                    onAccept = { acceptCall(callId, callType) },
                    onDecline = { declineCall(callId) }
                )
            }
        }

        stateListener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val state = snapshot.getValue(String::class.java) ?: return
                android.util.Log.d("IncomingCall", "Call state changed to: $state")
                when (state) {
                    "ENDED", "MISSED", "DECLINED" -> finish()
                }
            }
            override fun onCancelled(error: DatabaseError) {}
        }

        FirebaseDatabase.getInstance()
            .getReference("calls").child(callId).child("state")
            .addValueEventListener(stateListener!!)
    }

    private fun acceptCall(callId: String, callType: String) {
        hasAccepted = true

        FirebaseDatabase.getInstance()
            .getReference("calls").child(callId).child("state")
            .setValue("ACCEPTED")

        startService(Intent(this, CallService::class.java).apply {
            action = CallService.ACTION_ACCEPT_CALL
            putExtra("call_id", callId)
        })

        // 🔑 FIX: extra keys MUST match OngoingCallActivity's EXTRA_* constants
        startActivity(OngoingCallActivity.buildIntent(this, callId, callType, isCaller = false))
        finish()
    }

    private fun declineCall(callId: String) {
        FirebaseDatabase.getInstance()
            .getReference("calls").child(callId).child("state")
            .setValue("DECLINED")

        startService(Intent(this, CallService::class.java).apply {
            action = CallService.ACTION_DECLINE_CALL
        })
        finish()
    }

    override fun onDestroy() {
        super.onDestroy()
        val callId = intent.getStringExtra(EXTRA_CALL_ID)
        stateListener?.let { listener ->
            callId?.let {
                FirebaseDatabase.getInstance()
                    .getReference("calls").child(it).child("state")
                    .removeEventListener(listener)
            }
        }
    }
}

@Composable
private fun IncomingCallScreen(
    callId: String,
    callerName: String,
    callerPhotoBase64: String,
    isVideoCall: Boolean,
    onAccept: () -> Unit,
    onDecline: () -> Unit
) {
    Surface(modifier = Modifier.fillMaxSize(), color = Color(0xFF0B1F5C)) {
        Column(
            modifier = Modifier.fillMaxSize().padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Column(modifier = Modifier.padding(top = 64.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    text = if (isVideoCall) "Incoming video call" else "Incoming call",
                    color = Color.White.copy(alpha = 0.8f),
                    fontSize = 16.sp
                )

                Spacer(modifier = Modifier.height(24.dp))

                val photoBytes = remember(callerPhotoBase64) {
                    if (callerPhotoBase64.isNotBlank()) {
                        try { Base64.decode(callerPhotoBase64, Base64.NO_WRAP) } catch (_: Exception) { null }
                    } else null
                }

                Box(
                    modifier = Modifier.size(120.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center
                ) {
                    val bitmap = remember(photoBytes) {
                        photoBytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                    }
                    if (bitmap != null) {
                        Image(
                            bitmap = bitmap.asImageBitmap(),
                            contentDescription = "Caller photo",
                            modifier = Modifier.fillMaxSize().clip(CircleShape),
                            contentScale = ContentScale.Crop
                        )
                    } else {
                        Icon(Icons.Default.Person, contentDescription = null, tint = Color.White, modifier = Modifier.size(56.dp))
                    }
                }

                Spacer(modifier = Modifier.height(20.dp))
                Text(text = callerName, color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Bold)
            }

            Row(modifier = Modifier.fillMaxWidth().padding(bottom = 32.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                CallActionButton(Icons.Default.CallEnd, Color(0xFFE53935), "Decline") { onDecline() }
                CallActionButton(Icons.Default.Call, Color(0xFF43A047), "Accept") { onAccept() }
            }
        }
    }
}

@Composable
private fun CallActionButton(icon: ImageVector, backgroundColor: Color, contentDescription: String, onClick: () -> Unit) {
    IconButton(
        onClick = onClick,
        modifier = Modifier.size(64.dp).clip(CircleShape).background(backgroundColor)
    ) {
        Icon(icon, contentDescription = contentDescription, tint = Color.White, modifier = Modifier.size(30.dp))
    }
}