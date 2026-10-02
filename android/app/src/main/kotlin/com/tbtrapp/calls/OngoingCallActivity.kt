package com.tbtrapp.calls

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Bundle
import android.os.IBinder
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

/**
 * The in-call screen. Binds to (and, if needed, starts) [OngoingCallService],
 * which owns the actual WebRtcClient/PeerConnection — this Activity is just
 * the UI + controls layered on top, so it can be recreated (e.g. rotation)
 * without disturbing the call itself.
 */
class OngoingCallActivity : ComponentActivity(), OngoingCallService.CallListener {

    companion object {
        private const val EXTRA_CALL_ID = "call_id"
        private const val EXTRA_CALL_TYPE = "call_type"
        private const val EXTRA_IS_CALLER = "is_caller"
        private const val EXTRA_PEER_NAME = "peer_name"

        fun buildIntent(
            context: Context,
            callId: String,
            callType: String,
            isCaller: Boolean,
            peerName: String = "Unknown"
        ): Intent = Intent(context, OngoingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_CALL_ID, callId)
            putExtra(EXTRA_CALL_TYPE, callType)
            putExtra(EXTRA_IS_CALLER, isCaller)
            putExtra(EXTRA_PEER_NAME, peerName)
        }
    }

    private var callId: String = ""
    private var callType: String = "audio"
    private var isCaller: Boolean = false
    private var peerName: String = "Unknown"

    private var service: OngoingCallService? = null
    private var isBound = false

    private val isMuted = mutableStateOf(false)
    private val isSpeakerOn = mutableStateOf(true)
    private val statusText = mutableStateOf("Connecting…")

    private var localSurfaceView: SurfaceViewRenderer? = null
    private var remoteSurfaceView: SurfaceViewRenderer? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val bound = (binder as OngoingCallService.LocalBinder).getService()
            service = bound
            bound.setListener(this@OngoingCallActivity)
            bound.runWhenReady {
                if (callType.equals("video", ignoreCase = true)) {
                    localSurfaceView?.let { bound.webRtcClient.attachLocalPreview(it) }
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
        }
    }

    // Best-effort — the call proceeds either way (audio-only if camera denied);
    // the service already re-checks live permission state before using the camera.
    private val callPermissionsLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val id = intent.getStringExtra(EXTRA_CALL_ID)
        if (id == null) {
            finish()
            return
        }
        callId = id
        callType = intent.getStringExtra(EXTRA_CALL_TYPE) ?: "audio"
        isCaller = intent.getBooleanExtra(EXTRA_IS_CALLER, false)
        peerName = intent.getStringExtra(EXTRA_PEER_NAME) ?: "Unknown"

        val isVideo = callType.equals("video", ignoreCase = true)
        ensurePermissions(isVideo)

        if (isVideo) {
            localSurfaceView = SurfaceViewRenderer(this)
            remoteSurfaceView = SurfaceViewRenderer(this)
        }

        // Idempotent — if CallInitiator/CallActionReceiver already started the
        // service for this call, OngoingCallService.onStartCommand() sees
        // isInitialized == true and just re-asserts the foreground notification.
        val cameraGranted = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        val startIntent = OngoingCallService.buildStartIntent(
            this, callId, isCaller, callType, peerName, cameraGranted
        )
        ContextCompat.startForegroundService(this, startIntent)
        bindService(Intent(this, OngoingCallService::class.java), connection, Context.BIND_AUTO_CREATE)
        isBound = true

        renderUi()
    }

    private fun renderUi() {
        setContent {
            MaterialTheme {
                OngoingCallScreen(
                    peerName = peerName,
                    isVideoCall = callType.equals("video", ignoreCase = true),
                    statusText = statusText.value,
                    isMuted = isMuted.value,
                    isSpeakerOn = isSpeakerOn.value,
                    localView = localSurfaceView,
                    remoteView = remoteSurfaceView,
                    onToggleMute = { toggleMute() },
                    onToggleSpeaker = { toggleSpeaker() },
                    onSwitchCamera = { service?.webRtcClient?.switchCamera() },
                    onEndCall = { endCall() }
                )
            }
        }
    }

    private fun ensurePermissions(isVideo: Boolean) {
        val needed = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (isVideo) needed.add(Manifest.permission.CAMERA)
        val missing = needed.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) callPermissionsLauncher.launch(missing.toTypedArray())
    }

    private fun toggleMute() {
        val muted = !isMuted.value
        isMuted.value = muted
        service?.webRtcClient?.setAudioEnabled(!muted)
    }

    private fun toggleSpeaker() {
        val speakerOn = !isSpeakerOn.value
        isSpeakerOn.value = speakerOn
        val audioManager = getSystemService(AudioManager::class.java)
        audioManager?.isSpeakerphoneOn = speakerOn
    }

    private fun endCall() {
        service?.endCall()
        finish()
    }

    // ---- OngoingCallService.CallListener ----

    override fun onConnectionStateChanged(status: String) {
        runOnUiThread { statusText.value = status }
    }

    override fun onRemoteVideoTrack(track: VideoTrack) {
        runOnUiThread {
            remoteSurfaceView?.let { service?.webRtcClient?.attachRemotePreview(it) }
        }
    }

    override fun onCallEnded() {
        runOnUiThread { finish() }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (isBound) {
            try { unbindService(connection) } catch (_: Exception) {}
            isBound = false
        }
        try { localSurfaceView?.release() } catch (_: Exception) {}
        try { remoteSurfaceView?.release() } catch (_: Exception) {}
    }
}

@Composable
private fun OngoingCallScreen(
    peerName: String,
    isVideoCall: Boolean,
    statusText: String,
    isMuted: Boolean,
    isSpeakerOn: Boolean,
    localView: SurfaceViewRenderer?,
    remoteView: SurfaceViewRenderer?,
    onToggleMute: () -> Unit,
    onToggleSpeaker: () -> Unit,
    onSwitchCamera: () -> Unit,
    onEndCall: () -> Unit
) {
    Box(modifier = Modifier.fillMaxSize().background(Color(0xFF0B1F5C))) {
        if (isVideoCall && remoteView != null) {
            AndroidView(factory = { remoteView }, modifier = Modifier.fillMaxSize())
        }

        if (isVideoCall && localView != null) {
            AndroidView(
                factory = { localView },
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(16.dp)
                    .size(width = 100.dp, height = 140.dp)
                    .clip(RoundedCornerShape(12.dp))
            )
        }

        Column(
            modifier = Modifier.fillMaxSize().padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Column(
                modifier = Modifier.padding(top = 64.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(text = peerName, color = Color.White, fontSize = 26.sp)
                Spacer(modifier = Modifier.height(12.dp))
                Text(text = statusText, color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp)
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(24.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(
                    onClick = onToggleMute,
                    modifier = Modifier
                        .size(56.dp)
                        .clip(CircleShape)
                        .background(if (isMuted) Color.White else Color.White.copy(alpha = 0.2f))
                ) {
                    Icon(
                        imageVector = if (isMuted) Icons.Default.MicOff else Icons.Default.Mic,
                        contentDescription = "Mute",
                        tint = if (isMuted) Color(0xFF0B1F5C) else Color.White
                    )
                }

                IconButton(
                    onClick = onEndCall,
                    modifier = Modifier
                        .size(64.dp)
                        .clip(CircleShape)
                        .background(Color(0xFFE53935))
                ) {
                    Icon(
                        imageVector = Icons.Default.CallEnd,
                        contentDescription = "End call",
                        tint = Color.White,
                        modifier = Modifier.size(30.dp)
                    )
                }

                if (isVideoCall) {
                    IconButton(
                        onClick = onSwitchCamera,
                        modifier = Modifier
                            .size(56.dp)
                            .clip(CircleShape)
                            .background(Color.White.copy(alpha = 0.2f))
                    ) {
                        Icon(
                            imageVector = Icons.Default.Cameraswitch,
                            contentDescription = "Switch camera",
                            tint = Color.White
                        )
                    }
                } else {
                    IconButton(
                        onClick = onToggleSpeaker,
                        modifier = Modifier
                            .size(56.dp)
                            .clip(CircleShape)
                            .background(if (isSpeakerOn) Color.White else Color.White.copy(alpha = 0.2f))
                    ) {
                        Icon(
                            imageVector = if (isSpeakerOn) Icons.Default.VolumeUp else Icons.Default.VolumeOff,
                            contentDescription = "Speaker",
                            tint = if (isSpeakerOn) Color(0xFF0B1F5C) else Color.White
                        )
                    }
                }
            }
        }
    }
}
