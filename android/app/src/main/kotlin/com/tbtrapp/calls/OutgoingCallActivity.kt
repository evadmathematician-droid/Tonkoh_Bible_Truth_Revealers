package com.tbtrapp.calls

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener
import org.webrtc.*



class OutgoingCallActivity : ComponentActivity() {

    companion object {
        private const val EXTRA_CALL_ID = "call_id"
        private const val EXTRA_CALLEE_NAME = "callee_name"
        private const val EXTRA_CALL_TYPE = "call_type"

        fun buildIntent(
            context: Context,
            callId: String,
            calleeName: String,
            callType: String
        ): Intent = Intent(context, OutgoingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_CALL_ID, callId)
            putExtra(EXTRA_CALLEE_NAME, calleeName)
            putExtra(EXTRA_CALL_TYPE, callType)
        }
    }

    private var callId: String? = null
    private var callType: String = "audio"
    private var stateListener: ValueEventListener? = null

    // Plays the repeating outgoing-call ringback tone. Started as soon as this
    // screen appears, stopped the moment the call resolves in any way
    // (accepted / cancelled / declined / ended / missed) or the Activity dies.
    private val ringbackManager = RingbackManager()

    // Lightweight preview stack — no PeerConnection, just camera → screen
    private var previewEglBase: EglBase? = null
    private var previewView: SurfaceViewRenderer? = null
    private var previewFactory: PeerConnectionFactory? = null
    private var previewCapturer: CameraVideoCapturer? = null
    private var previewVideoTrack: VideoTrack? = null

    // CAMERA is a dangerous permission — the manifest entry alone does nothing
    // on API 23+. Without this runtime request, WebRTC's Camera2Session throws
    // SecurityException on every attempt to open the camera (silently retried
    // and eventually dropped, so video calls just show a black/frozen preview
    // with a live audio-only call underneath). RECORD_AUDIO is requested here
    // too since it's needed for both audio and video calls and this is the
    // natural point to ask for both together.
    private val callPermissionsLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        val cameraGranted = results[Manifest.permission.CAMERA] == true
        val micGranted = results[Manifest.permission.RECORD_AUDIO] == true
        Log.d("OutgoingCall", "Permissions result — camera=$cameraGranted mic=$micGranted")

        if (callType.equals("video", ignoreCase = true) && cameraGranted) {
            initCameraPreview()
        }
        // If mic was denied, the call still proceeds — OngoingCallActivity/
        // WebRTC will surface that failure when it tries to open the mic.
        // If camera was denied on a video call, we deliberately continue
        // without a local preview rather than blocking the call outright;
        // the remote side and audio path are unaffected.
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        callId = intent.getStringExtra(EXTRA_CALL_ID)
        if (callId == null) {
            Log.e("OutgoingCall", "Missing call_id extra")
            finish()
            return
        }
        val calleeName = intent.getStringExtra(EXTRA_CALLEE_NAME) ?: "Unknown"
        callType = intent.getStringExtra(EXTRA_CALL_TYPE) ?: "audio"
        val isVideo = callType.equals("video", ignoreCase = true)

        ensureCallPermissions(isVideo)

        // Start ringback the moment the outgoing-call screen is shown.
        ringbackManager.start()

        setContent {
            MaterialTheme {
                OutgoingCallScreen(
                    calleeName = calleeName,
                    isVideoCall = isVideo,
                    previewView = previewView,
                    onCancel = { cancelCall() }
                )
            }
        }

        val ref = FirebaseDatabase.getInstance().getReference("calls").child(callId!!).child("state")
        stateListener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val state = snapshot.getValue(String::class.java) ?: return
                Log.d("OutgoingCall", "State changed to: $state")
                when (state) {
                    "ACCEPTED" -> onCallAccepted()
                    "DECLINED", "ENDED", "MISSED" -> {
                        // These paths bypass cancelCall() entirely, so the
                        // ringback loop must be stopped here too — otherwise
                        // it keeps reposting itself via Handler after finish().
                        ringbackManager.stop()
                        finish()
                    }
                }
            }
            override fun onCancelled(error: DatabaseError) {}
        }
        ref.addValueEventListener(stateListener!!)
    }

    /**
     * Requests CAMERA (video calls only) and RECORD_AUDIO (always) at runtime
     * if not already granted. If everything needed is already granted, starts
     * the camera preview immediately — otherwise waits for the launcher
     * callback above to do it once the user responds.
     */
    private fun ensureCallPermissions(isVideo: Boolean) {
        val needed = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (isVideo) needed.add(Manifest.permission.CAMERA)

        val missing = needed.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (missing.isEmpty()) {
            if (isVideo) initCameraPreview()
            return
        }

        callPermissionsLauncher.launch(missing.toTypedArray())
    }

    /** Caller sees themselves while the phone rings. */
    private fun initCameraPreview() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w("OutgoingCall", "initCameraPreview called without CAMERA permission — skipping")
            return
        }
        try {
            previewEglBase = EglBase.create()
            previewView = SurfaceViewRenderer(this).apply {
                init(previewEglBase!!.eglBaseContext, null)
                setMirror(true)
                setEnableHardwareScaler(true)
            }

            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions.builder(this)
                    .createInitializationOptions()
            )
            val factory = PeerConnectionFactory.builder().createPeerConnectionFactory()
            previewFactory = factory

            val videoSource = factory.createVideoSource(false)
            val capturer = createCameraCapturer()
            previewCapturer = capturer

            val helper = SurfaceTextureHelper.create("PreviewThread", previewEglBase!!.eglBaseContext)
            capturer?.initialize(helper, this, videoSource.capturerObserver)
            capturer?.startCapture(1280, 720, 30)

            previewVideoTrack = factory.createVideoTrack("PREVIEW_TRACK", videoSource)
            previewVideoTrack?.addSink(previewView)
            Log.d("OutgoingCall", "Camera preview started")

            // previewView didn't exist yet when setContent() first ran (permission
            // was still pending), so recompose now that it's ready to display it.
            setContent {
                MaterialTheme {
                    OutgoingCallScreen(
                        calleeName = intent.getStringExtra(EXTRA_CALLEE_NAME) ?: "Unknown",
                        isVideoCall = callType.equals("video", ignoreCase = true),
                        previewView = previewView,
                        onCancel = { cancelCall() }
                    )
                }
            }
        } catch (e: Exception) {
            Log.e("OutgoingCall", "Camera preview failed: ${e.message}", e)
        }
    }

    private fun createCameraCapturer(): CameraVideoCapturer? {
        val enumerator = Camera2Enumerator(this)
        val deviceNames = enumerator.deviceNames
        for (name in deviceNames) {
            if (enumerator.isFrontFacing(name)) {
                return enumerator.createCapturer(name, null)
            }
        }
        for (name in deviceNames) {
            return enumerator.createCapturer(name, null)
        }
        return null
    }

    private fun onCallAccepted() {
        Log.d("OutgoingCall", "Call accepted — handing off to OngoingCallActivity")
        ringbackManager.stop()
        releasePreview()
        startActivity(
            OngoingCallActivity.buildIntent(
                context = this,
                callId = callId!!,
                callType = callType,
                isCaller = true
            )
        )
        finish()
    }

    private fun cancelCall() {
        Log.d("OutgoingCall", "Caller cancelled")
        ringbackManager.stop()
        callId?.let {
            FirebaseDatabase.getInstance().getReference("calls").child(it).child("state")
                .setValue("ENDED")
        }
        releasePreview()
        finish()
    }

    private fun releasePreview() {
        try { previewCapturer?.stopCapture() } catch (_: Exception) {}
        try { previewCapturer?.dispose() } catch (_: Exception) {}
        previewCapturer = null

        try { previewVideoTrack?.dispose() } catch (_: Exception) {}
        previewVideoTrack = null

        try { previewView?.release() } catch (_: Exception) {}
        previewView = null

        try { previewEglBase?.release() } catch (_: Exception) {}
        previewEglBase = null

        try { previewFactory?.dispose() } catch (_: Exception) {}
        previewFactory = null
    }

    override fun onDestroy() {
        super.onDestroy()
        // Safety net: guarantees the ringback loop can never keep running/
        // leaking past this Activity's lifetime, regardless of which exit
        // path was taken above.
        ringbackManager.stop()
        releasePreview()
        stateListener?.let { listener ->
            callId?.let { id ->
                FirebaseDatabase.getInstance().getReference("calls").child(id).child("state")
                    .removeEventListener(listener)
            }
        }
    }
}

@Composable
private fun OutgoingCallScreen(
    calleeName: String,
    isVideoCall: Boolean,
    previewView: SurfaceViewRenderer?,
    onCancel: () -> Unit
) {
    Box(modifier = Modifier.fillMaxSize().background(Color(0xFF0B1F5C))) {
        // Caller camera preview (sees themselves while ringing)
        if (isVideoCall && previewView != null) {
            AndroidView(
                factory = { previewView },
                modifier = Modifier.fillMaxSize()
            )
            // Dark overlay so text/buttons remain readable
            Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)))
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
                Text(
                    text = if (isVideoCall) "Outgoing video call" else "Outgoing call",
                    color = Color.White.copy(alpha = 0.8f),
                    fontSize = 16.sp
                )
                Spacer(modifier = Modifier.height(24.dp))
                Text(
                    text = calleeName,
                    color = Color.White,
                    fontSize = 26.sp
                )
                Spacer(modifier = Modifier.height(12.dp))
                Text(
                    text = "Ringing…",
                    color = Color.White.copy(alpha = 0.7f),
                    fontSize = 14.sp
                )
            }

            IconButton(
                onClick = onCancel,
                modifier = Modifier
                    .size(64.dp)
                    .clip(CircleShape)
                    .background(Color(0xFFE53935))
            ) {
                Icon(
                    imageVector = Icons.Default.CallEnd,
                    contentDescription = "Cancel",
                    tint = Color.White,
                    modifier = Modifier.size(30.dp)
                )
            }
        }
    }
}