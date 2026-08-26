package com.tbtrapp.calls

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.addCallback
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

class OngoingCallActivity : ComponentActivity() {

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
            peerName: String = ""
        ): Intent = Intent(context, OngoingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_CALL_ID, callId)
            putExtra(EXTRA_CALL_TYPE, callType)
            putExtra(EXTRA_IS_CALLER, isCaller)
            putExtra(EXTRA_PEER_NAME, peerName)
        }
    }

    // ---- Camera-permission "permanently denied" recovery dialog state ----

    private val showCameraSettingsDialog = mutableStateOf(false)

    private fun prefs(): SharedPreferences =
        getSharedPreferences("call_permissions", MODE_PRIVATE)

    private fun hasRequestedCameraBefore(): Boolean =
        prefs().getBoolean("camera_requested_before", false)

    private fun markCameraRequested() {
        prefs().edit().putBoolean("camera_requested_before", true).apply()
    }

    private fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
        }
        startActivity(intent)
    }

    // ------------------------------------------------------------------

    private lateinit var callId: String
    private lateinit var callType: String
    private var isCaller: Boolean = false
    private var peerName: String = ""

    private var service: OngoingCallService? = null
    private var bound = false

    private var localView: SurfaceViewRenderer? = null
    private var remoteView: SurfaceViewRenderer? = null

    private val connectionStatus = mutableStateOf("Connecting…")
    private val remoteTrack = mutableStateOf<VideoTrack?>(null)

    // Guards against a rapid double-tap on the End-call button dispatching
    // endCall()/finish() twice in a row.
    private var endCallRequested = false

    private val callListener = object : OngoingCallService.CallListener {
        override fun onConnectionStateChanged(status: String) {
            runOnUiThread { connectionStatus.value = status }
        }
        override fun onRemoteVideoTrack(track: VideoTrack) {
            runOnUiThread {
                remoteTrack.value = track
                remoteView?.let { service?.webRtcClient?.attachRemotePreview(it) }
            }
        }
        override fun onCallEnded() {
            runOnUiThread { finish() }
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val localBinder = binder as OngoingCallService.LocalBinder
            val svc = localBinder.getService()
            service = svc
            bound = true
            svc.setListener(callListener)

            // FIX: bind race. startCallService() fires startForegroundService()
            // and bindService() back to back, and Android gives no guarantee
            // that onStartCommand() (which constructs webRtcClient inside
            // initCall()) runs before this onServiceConnected() callback. Calling
            // attachRenderers() straight from here could read svc.webRtcClient
            // before it existed, throwing UninitializedPropertyAccessException.
            //
            // runWhenReady() fires immediately if initCall() already ran, or
            // queues this and runs it the moment webRtcClient is constructed —
            // so the ordering is handled explicitly instead of assumed.
            svc.runWhenReady {
                // The Activity may have moved through onStop()/unbound by the
                // time this fires (e.g. user backed out during a slow service
                // start-up). Guard against attaching renderers to a service
                // we're no longer bound to.
                if (bound && service === svc) {
                    attachRenderers()
                }
            }
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            bound = false
            service = null
        }
    }

    private val callPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        val micGranted = results[Manifest.permission.RECORD_AUDIO]
            ?: (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
        val camGranted = results[Manifest.permission.CAMERA]
            ?: (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)

        if (!micGranted) {
            Log.e("OngoingCallActivity", "RECORD_AUDIO denied — cannot start call without mic")
            finish()
            return@registerForActivityResult
        }

        val isVideo = callType.equals("video", ignoreCase = true)
        if (isVideo && !camGranted) {
            val permanentlyDenied = hasRequestedCameraBefore() &&
                    !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)
            if (permanentlyDenied) {
                showCameraSettingsDialog.value = true
            }
        }
        markCameraRequested()

        startCallService(cameraGranted = camGranted)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val extraCallId = intent.getStringExtra(EXTRA_CALL_ID)
        if (extraCallId == null) {
            Log.e("OngoingCallActivity", "Missing $EXTRA_CALL_ID — finishing")
            finish()
            return
        }
        callId = extraCallId
        callType = intent.getStringExtra(EXTRA_CALL_TYPE) ?: "audio"
        isCaller = intent.getBooleanExtra(EXTRA_IS_CALLER, false)
        peerName = intent.getStringExtra(EXTRA_PEER_NAME) ?: ""

        localView = SurfaceViewRenderer(this).apply { setMirror(true); setEnableHardwareScaler(true) }
        remoteView = SurfaceViewRenderer(this).apply { setEnableHardwareScaler(true) }

        setContent {
            MaterialTheme {
                var isMuted by remember { mutableStateOf(false) }
                var isSpeakerOn by remember { mutableStateOf(callType.equals("video", true)) }
                var isVideoEnabled by remember { mutableStateOf(true) }

                OngoingCallScreen(
                    connectionStatus = connectionStatus.value,
                    isVideoCall = callType.equals("video", ignoreCase = true),
                    isMuted = isMuted,
                    isSpeakerOn = isSpeakerOn,
                    isVideoEnabled = isVideoEnabled,
                    onToggleMute = {
                        isMuted = !isMuted
                        service?.webRtcClient?.setAudioEnabled(!isMuted)
                    },
                    onToggleSpeaker = {
                        isSpeakerOn = !isSpeakerOn
                        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        am.isSpeakerphoneOn = isSpeakerOn
                    },
                    onToggleVideo = {
                        isVideoEnabled = !isVideoEnabled
                        service?.webRtcClient?.setVideoEnabled(isVideoEnabled)
                    },
                    onSwitchCamera = { service?.webRtcClient?.switchCamera() },
                    onEndCall = { onEndCallRequested() },
                    localView = localView!!,
                    remoteView = remoteView!!
                )

                // Shown when CAMERA permission is permanently denied so the
                // user understands why their video isn't sending, and can
                // jump straight to the fix instead of guessing.
                if (showCameraSettingsDialog.value) {
                    AlertDialog(
                        onDismissRequest = { showCameraSettingsDialog.value = false },
                        title = { Text("Camera access needed") },
                        text = {
                            Text(
                                "Camera permission is turned off for this app, so the other " +
                                        "person can't see your video. Enable it in Settings to use video calls."
                            )
                        },
                        confirmButton = {
                            TextButton(onClick = {
                                showCameraSettingsDialog.value = false
                                openAppSettings()
                            }) { Text("Open Settings") }
                        },
                        dismissButton = {
                            TextButton(onClick = { showCameraSettingsDialog.value = false }) {
                                Text("Continue with audio only")
                            }
                        }
                    )
                }
            }
        }

        requestCallPermissionsAndStart()

        // FIX: with no back-press override, the system default finishes this
        // Activity on back — which tears down the renderers/UI (onStop ->
        // detachRenderers/unbind, onDestroy -> release both SurfaceViewRenderers)
        // and looks exactly like the call "stopped", even though nothing
        // explicitly ended it. A call in progress should never be dismissable
        // by accident via back — send the app to the background instead (same
        // as pressing Home), so the call and its foreground service stay fully
        // alive underneath. Only the explicit End Call button below
        // (onEndCallRequested) should ever actually end the call.
        onBackPressedDispatcher.addCallback(this) {
            moveTaskToBack(true)
        }
    }

    // FIX: previously `onEndCall = { service?.endCall() ?: finish() }` could fire twice
    // from a fast double-tap before recomposition disabled the button, dispatching two
    // endCall() calls (or an endCall() + a finish() race). WebRtcClient.endCall() is now
    // internally idempotent too, but guarding here avoids the redundant second dispatch
    // and the resulting duplicate finish() calls.
    private fun onEndCallRequested() {
        if (endCallRequested) return
        endCallRequested = true
        service?.endCall() ?: finish()
    }

    private fun requestCallPermissionsAndStart() {
        val isVideo = callType.equals("video", ignoreCase = true)

        // If camera is permanently denied, requesting it again would just
        // silently return false with no dialog. Detect that case up front
        // and show our own explanation immediately, rather than only after
        // a wasted round-trip through the permission launcher.
        if (isVideo &&
            checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED &&
            hasRequestedCameraBefore() &&
            !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)
        ) {
            showCameraSettingsDialog.value = true
            // Proceed mic-only so the call isn't blocked entirely.
            startCallService(cameraGranted = false)
            return
        }

        val needed = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (isVideo) needed += Manifest.permission.CAMERA

        val missing = needed.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }

        if (missing.isEmpty()) {
            startCallService(cameraGranted = isVideo)
        } else {
            callPermissionLauncher.launch(missing.toTypedArray())
        }
    }

    private fun startCallService(cameraGranted: Boolean) {
        val startIntent = OngoingCallService.buildStartIntent(
            this, callId, isCaller, callType, peerName, cameraGranted
        )
        startForegroundService(startIntent)
        bindService(Intent(this, OngoingCallService::class.java), connection, Context.BIND_AUTO_CREATE)
    }

    private fun attachRenderers() {
        val svc = service ?: return
        val eglContext = svc.webRtcClient.eglBaseContext

        try { remoteView?.init(eglContext, null) } catch (_: IllegalStateException) {}
        remoteView?.let { svc.webRtcClient.attachRemotePreview(it) }

        if (callType.equals("video", ignoreCase = true)) {
            try { localView?.init(eglContext, null) } catch (_: IllegalStateException) {}
            localView?.let { svc.webRtcClient.attachLocalPreview(it) }
        }
    }

    private fun detachRenderers() {
        val svc = service ?: return
        localView?.let { svc.webRtcClient.detachLocalPreview(it) }
        remoteView?.let { svc.webRtcClient.detachRemotePreview(it) }
    }

    override fun onStart() {
        super.onStart()
        if (!bound && ::callId.isInitialized) {
            bindService(Intent(this, OngoingCallService::class.java), connection, Context.BIND_AUTO_CREATE)
        }
    }

    override fun onStop() {
        super.onStop()
        detachRenderers()
        if (bound) {
            service?.setListener(null)
            unbindService(connection)
            bound = false
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try { localView?.release() } catch (_: Exception) {}
        try { remoteView?.release() } catch (_: Exception) {}
    }
}

@Composable
private fun OngoingCallScreen(
    connectionStatus: String,
    isVideoCall: Boolean,
    isMuted: Boolean,
    isSpeakerOn: Boolean,
    isVideoEnabled: Boolean,
    onToggleMute: () -> Unit,
    onToggleSpeaker: () -> Unit,
    onToggleVideo: () -> Unit,
    onSwitchCamera: () -> Unit,
    onEndCall: () -> Unit,
    localView: SurfaceViewRenderer,
    remoteView: SurfaceViewRenderer
) {
    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        if (isVideoCall) {
            AndroidView(factory = { remoteView }, modifier = Modifier.fillMaxSize())
            if (isVideoEnabled) {
                AndroidView(
                    factory = { localView },
                    modifier = Modifier
                        .size(120.dp, 160.dp)
                        .align(Alignment.TopEnd)
                        .padding(16.dp)
                )
            }
        }

        Column(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.SpaceBetween,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(text = connectionStatus, color = Color.White, modifier = Modifier.padding(top = 48.dp))

            Row(
                modifier = Modifier.fillMaxWidth().padding(bottom = 32.dp),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                if (isVideoCall) {
                    ControlButton(icon = if (isVideoEnabled) Icons.Default.Videocam else Icons.Default.VideocamOff, onClick = onToggleVideo)
                    ControlButton(icon = Icons.Default.Cameraswitch, onClick = onSwitchCamera)
                }
                ControlButton(icon = if (isMuted) Icons.Default.MicOff else Icons.Default.Mic, onClick = onToggleMute)
                ControlButton(icon = if (isSpeakerOn) Icons.Default.VolumeUp else Icons.Default.VolumeOff, onClick = onToggleSpeaker)
                ControlButton(icon = Icons.Default.CallEnd, tint = Color(0xFFE53935), onClick = onEndCall)
            }
        }
    }
}

@Composable
private fun ControlButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color = Color.White,
    onClick: () -> Unit
) {
    IconButton(
        onClick = onClick,
        modifier = Modifier.size(56.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.2f))
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(28.dp))
    }
}