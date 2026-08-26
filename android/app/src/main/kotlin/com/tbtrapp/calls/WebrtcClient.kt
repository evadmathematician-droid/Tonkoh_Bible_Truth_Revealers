// WebRtcClient.kt — FIX: attachRemotePreview() now calls surfaceView.init() before
// addSink(), mirroring attachLocalPreview(). Previously the remote SurfaceViewRenderer
// was never init()'d, so addSink() succeeded silently but nothing ever rendered —
// this was why remote video never displayed on either end while local video and
// audio both worked fine. Rest of the file is unchanged from what you posted.
package com.tbtrapp.call

import android.content.Context
import android.media.AudioManager
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.webrtc.*
import org.webrtc.audio.JavaAudioDeviceModule
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit

class WebRtcClient(
    private val context: Context,
    private val eglBase: EglBase,
    private val listener: Listener
) {
    interface Listener {
        fun onLocalIceCandidate(candidate: IceCandidateModel)
        fun onRemoteVideoTrack(track: VideoTrack)
        fun onConnectionStateChanged(state: PeerConnection.PeerConnectionState)
    }

    companion object {
        private const val TAG = "WebRtcClient"
        private const val TURN_CREDS_ENDPOINT = "https://small-dream-b231.tonkohbibletruthrevealers.workers.dev"
    }

    val eglBaseContext: EglBase.Context get() = eglBase.eglBaseContext

    private lateinit var factory: PeerConnectionFactory
    private var peerConnection: PeerConnection? = null
    private var localVideoTrack: VideoTrack? = null
    private var localAudioTrackReal: AudioTrack? = null
    private var videoCapturer: CameraVideoCapturer? = null

    private var localVideoSink: VideoSink? = null
    private var remoteVideoTrackRef: VideoTrack? = null
    private var remoteVideoSink: VideoSink? = null

    private val pendingRemoteCandidates = ConcurrentLinkedQueue<IceCandidate>()
    @Volatile private var remoteDescriptionSet = false

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    suspend fun fetchIceServers(): List<PeerConnection.IceServer> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder()
                .url(TURN_CREDS_ENDPOINT)
                .post("".toRequestBody(null))
                .build()

            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    Log.e(TAG, "TURN creds fetch failed: HTTP ${response.code}")
                    return@withContext fallbackStunOnly()
                }

                val body = response.body?.string()
                if (body.isNullOrBlank()) {
                    Log.e(TAG, "TURN creds fetch returned empty body")
                    return@withContext fallbackStunOnly()
                }

                val iceServersObj = JSONObject(body).getJSONObject("iceServers")
                val urls = iceServersObj.getJSONArray("urls")
                val username = iceServersObj.optString("username", "")
                val credential = iceServersObj.optString("credential", "")

                val servers = mutableListOf<PeerConnection.IceServer>()
                for (i in 0 until urls.length()) {
                    val url = urls.getString(i)
                    val builder = PeerConnection.IceServer.builder(url)
                    if (url.startsWith("turn:") || url.startsWith("turns:")) {
                        builder.setUsername(username).setPassword(credential)
                    }
                    servers.add(builder.createIceServer())
                }

                if (servers.none { it.urls.any { u -> u.startsWith("turn") } }) {
                    Log.w(TAG, "No TURN entries in response — STUN-only fallback")
                }

                Log.d(TAG, "Fetched ${servers.size} ICE servers from Worker")
                servers
            }
        } catch (e: Exception) {
            Log.e(TAG, "TURN creds fetch exception: ${e.message}", e)
            fallbackStunOnly()
        }
    }

    private fun fallbackStunOnly(): List<PeerConnection.IceServer> = listOf(
        PeerConnection.IceServer.builder("stun:stun.cloudflare.com:3478").createIceServer(),
        PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer(),
    )

    fun initFactory() {
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context)
                .createInitializationOptions()
        )
        val encoderFactory = DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true)
        val decoderFactory = DefaultVideoDecoderFactory(eglBase.eglBaseContext)

        val audioDeviceModule = JavaAudioDeviceModule.builder(context)
            .setUseHardwareAcousticEchoCanceler(true)
            .setUseHardwareNoiseSuppressor(true)
            .createAudioDeviceModule()

        factory = PeerConnectionFactory.builder()
            .setAudioDeviceModule(audioDeviceModule)
            .setVideoEncoderFactory(encoderFactory)
            .setVideoDecoderFactory(decoderFactory)
            .createPeerConnectionFactory()
    }

    fun setupLocalMedia(
        isVideo: Boolean,
        localSurfaceView: SurfaceViewRenderer? = null
    ): MediaStream {
        Log.d(TAG, "setupLocalMedia called with isVideo=$isVideo, hasSurface=${localSurfaceView != null}")

        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        audioManager.isSpeakerphoneOn = isVideo

        val audioSource = factory.createAudioSource(MediaConstraints())
        localAudioTrackReal = factory.createAudioTrack("AUDIO_TRACK", audioSource)
        localAudioTrackReal?.setEnabled(true)

        val stream = factory.createLocalMediaStream("LOCAL_STREAM")
        localAudioTrackReal?.let { stream.addTrack(it) }

        if (isVideo) {
            val videoSource = factory.createVideoSource(false)
            videoCapturer = createCameraCapturer()
            Log.d(TAG, "createCameraCapturer() returned: ${videoCapturer != null}")

            if (videoCapturer == null) {
                Log.e(TAG, "No camera capturer available — falling back to audio-only")
            }

            val surfaceTextureHelper = SurfaceTextureHelper.create("CaptureThread", eglBase.eglBaseContext)
            videoCapturer?.initialize(surfaceTextureHelper, context, videoSource.capturerObserver)
            try {
                videoCapturer?.startCapture(1280, 720, 30)
                Log.d(TAG, "startCapture() called successfully")
            } catch (e: Exception) {
                Log.e(TAG, "startCapture() threw: ${e.message}", e)
            }
            localVideoTrack = factory.createVideoTrack("VIDEO_TRACK", videoSource)
            localSurfaceView?.let { attachLocalPreview(it) }
            localVideoTrack?.let { stream.addTrack(it) }
        }
        return stream
    }

    fun attachLocalPreview(surfaceView: SurfaceViewRenderer) {
        try {
            surfaceView.init(eglBase.eglBaseContext, null)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "localSurfaceView already initialized, skipping init()")
        }
        localVideoSink?.let { localVideoTrack?.removeSink(it) }
        localVideoTrack?.addSink(surfaceView)
        localVideoSink = surfaceView
    }

    fun detachLocalPreview(surfaceView: SurfaceViewRenderer) {
        localVideoTrack?.removeSink(surfaceView)
        if (localVideoSink === surfaceView) localVideoSink = null
    }

    // FIX: was missing surfaceView.init(eglBase.eglBaseContext, null) before addSink().
    // An un-init()'d SurfaceViewRenderer accepts addSink() without error but never
    // actually renders any frames — this was the entire bug. Now mirrors
    // attachLocalPreview() exactly.
    fun attachRemotePreview(surfaceView: SurfaceViewRenderer) {
        try {
            surfaceView.init(eglBase.eglBaseContext, null)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "remoteSurfaceView already initialized, skipping init()")
        }
        remoteVideoSink?.let { remoteVideoTrackRef?.removeSink(it) }
        remoteVideoTrackRef?.addSink(surfaceView)
        remoteVideoSink = surfaceView
    }

    fun detachRemotePreview(surfaceView: SurfaceViewRenderer) {
        remoteVideoTrackRef?.removeSink(surfaceView)
        if (remoteVideoSink === surfaceView) remoteVideoSink = null
    }

    private fun createCameraCapturer(): CameraVideoCapturer? {
        val enumerator = Camera2Enumerator(context)
        val deviceNames = enumerator.deviceNames
        for (name in deviceNames) {
            if (enumerator.isFrontFacing(name)) {
                enumerator.createCapturer(name, null)?.let { return it }
            }
        }
        for (name in deviceNames) {
            enumerator.createCapturer(name, null)?.let { return it }
        }
        return null
    }

    fun createPeerConnection(localStream: MediaStream, iceServers: List<PeerConnection.IceServer>) {
        val rtcConfig = PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
            iceTransportsType = PeerConnection.IceTransportsType.ALL
        }
        peerConnection = factory.createPeerConnection(rtcConfig, object : PeerConnection.Observer {
            override fun onIceCandidate(candidate: IceCandidate) {
                listener.onLocalIceCandidate(
                    IceCandidateModel(candidate.sdpMid ?: "", candidate.sdpMLineIndex, candidate.sdp)
                )
            }
            override fun onAddStream(stream: MediaStream?) {}
            override fun onTrack(transceiver: RtpTransceiver?) {
                val track = transceiver?.receiver?.track()
                Log.d(TAG, "onTrack fired: kind=${track?.kind()} id=${track?.id()}")
                when (track) {
                    is VideoTrack -> {
                        remoteVideoTrackRef = track
                        remoteVideoSink?.let { track.addSink(it) }
                        listener.onRemoteVideoTrack(track)
                    }
                    is AudioTrack -> {
                        Log.d(TAG, "Remote AUDIO track received — enabling")
                        track.setEnabled(true)
                    }
                }
            }
            override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {
                listener.onConnectionStateChanged(newState)
            }
            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
            override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState?) {
                Log.d(TAG, "ICE connection state: $newState")
            }
            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState?) {
                Log.d(TAG, "ICE gathering state: $newState")
            }
            override fun onAddTrack(receiver: RtpReceiver?, mediaStreams: Array<out MediaStream>?) {}
            override fun onSignalingChange(newState: PeerConnection.SignalingState?) {}
            override fun onRemoveStream(stream: MediaStream?) {}
            override fun onDataChannel(dataChannel: DataChannel?) {}
            override fun onRenegotiationNeeded() {}
        })

        localStream.audioTracks.forEach { track ->
            peerConnection?.addTrack(track, listOf(localStream.id))
        }
        localStream.videoTracks.forEach { track ->
            peerConnection?.addTrack(track, listOf(localStream.id))
        }
    }

    fun createOffer(onSdpReady: (String) -> Unit) {
        val constraints = MediaConstraints()
        peerConnection?.createOffer(object : SdpObserverAdapter() {
            override fun onCreateSuccess(desc: SessionDescription?) {
                if (desc == null) {
                    Log.e(TAG, "createOffer returned null SDP")
                    return
                }
                peerConnection?.setLocalDescription(object : SdpObserverAdapter() {
                    override fun onSetSuccess() {
                        Log.d(TAG, "setLocalDescription(offer) success")
                        onSdpReady(desc.description)
                    }
                    override fun onSetFailure(error: String?) {
                        Log.e(TAG, "setLocalDescription(offer) failed: $error")
                    }
                }, desc)
            }
            override fun onCreateFailure(error: String?) {
                Log.e(TAG, "createOffer failed: $error")
            }
        }, constraints)
    }

    fun createAnswer(onSdpReady: (String) -> Unit) {
        val constraints = MediaConstraints()
        peerConnection?.createAnswer(object : SdpObserverAdapter() {
            override fun onCreateSuccess(desc: SessionDescription?) {
                if (desc == null) {
                    Log.e(TAG, "createAnswer returned null SDP")
                    return
                }
                peerConnection?.setLocalDescription(object : SdpObserverAdapter() {
                    override fun onSetSuccess() {
                        Log.d(TAG, "setLocalDescription(answer) success")
                        onSdpReady(desc.description)
                    }
                    override fun onSetFailure(error: String?) {
                        Log.e(TAG, "setLocalDescription(answer) failed: $error")
                    }
                }, desc)
            }
            override fun onCreateFailure(error: String?) {
                Log.e(TAG, "createAnswer failed: $error")
            }
        }, constraints)
    }

    fun setRemoteOffer(sdp: String, onSetSuccess: (() -> Unit)? = null) {
        peerConnection?.setRemoteDescription(
            object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    Log.d(TAG, "setRemoteDescription(offer) success")
                    onRemoteDescriptionApplied()
                    onSetSuccess?.invoke()
                }
                override fun onSetFailure(error: String?) {
                    Log.e(TAG, "setRemoteDescription(offer) failed: $error")
                }
            },
            SessionDescription(SessionDescription.Type.OFFER, sdp)
        )
    }

    fun setRemoteAnswer(sdp: String) {
        peerConnection?.setRemoteDescription(
            object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    Log.d(TAG, "setRemoteDescription(answer) success")
                    onRemoteDescriptionApplied()
                }
                override fun onSetFailure(error: String?) {
                    Log.e(TAG, "setRemoteDescription(answer) failed: $error")
                }
            },
            SessionDescription(SessionDescription.Type.ANSWER, sdp)
        )
    }

    private fun onRemoteDescriptionApplied() {
        remoteDescriptionSet = true
        while (true) {
            val candidate = pendingRemoteCandidates.poll() ?: break
            peerConnection?.addIceCandidate(candidate)
        }
    }

    fun addRemoteIceCandidate(model: IceCandidateModel) {
        val candidate = IceCandidate(model.sdpMid, model.sdpMLineIndex, model.candidate)
        if (remoteDescriptionSet) {
            peerConnection?.addIceCandidate(candidate)
        } else {
            pendingRemoteCandidates.add(candidate)
        }
    }

    fun setAudioEnabled(enabled: Boolean) {
        localAudioTrackReal?.setEnabled(enabled)
    }

    fun setVideoEnabled(enabled: Boolean) {
        localVideoTrack?.setEnabled(enabled)
    }

    fun switchCamera() {
        videoCapturer?.switchCamera(null)
    }

    private var hasEnded = false

    /**
     * FIX: two bugs were causing the `Java_org_webrtc_PeerConnection_nativeClose`
     * SIGSEGVs:
     *
     * 1. `hasEnded` was checked and set as two separate non-atomic steps, so two
     *    near-simultaneous calls to endCall() (e.g. End-call button + a hangup
     *    callback firing around the same time) could both slip past the guard and
     *    double-close/double-dispose the same native PeerConnection — a double free.
     *    Now the check-and-set happens inside `synchronized`.
     *
     * 2. Local tracks/capturer were being disposed BEFORE `peerConnection.close()`.
     *    PeerConnection.close() walks its senders/receivers, which still reference
     *    the native track objects; freeing the tracks first left it dereferencing
     *    already-freed memory. Now `peerConnection.close()` runs first, and track/
     *    capturer disposal happens after — `peerConnection.dispose()` (the final
     *    native free) runs last, once nothing else references it.
     */
    fun endCall() {
        synchronized(this) {
            if (hasEnded) return
            hasEnded = true
        }

        try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_NORMAL
            audioManager.isSpeakerphoneOn = false
        } catch (_: Exception) {}

        pendingRemoteCandidates.clear()

        // Detach sinks first so we never touch a Surface after it's gone.
        try { localVideoSink?.let { localVideoTrack?.removeSink(it) } } catch (_: Exception) {}
        try { remoteVideoSink?.let { remoteVideoTrackRef?.removeSink(it) } } catch (_: Exception) {}
        localVideoSink = null
        remoteVideoSink = null
        remoteVideoTrackRef = null

        // Close the PeerConnection BEFORE disposing the tracks it still references.
        try { peerConnection?.close() } catch (_: Exception) {}

        try { videoCapturer?.stopCapture() } catch (_: Exception) {}
        try { videoCapturer?.dispose() } catch (_: Exception) {}
        videoCapturer = null

        try { localVideoTrack?.dispose() } catch (_: Exception) {}
        localVideoTrack = null
        try { localAudioTrackReal?.dispose() } catch (_: Exception) {}
        localAudioTrackReal = null

        // Now safe to fully free the PeerConnection's native memory.
        try { peerConnection?.dispose() } catch (_: Exception) {}
        peerConnection = null

        try { if (::factory.isInitialized) factory.dispose() } catch (_: Exception) {}
    }

    open class SdpObserverAdapter : SdpObserver {
        override fun onCreateSuccess(p0: SessionDescription?) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(p0: String?) { Log.e(TAG, "SDP create failure: $p0") }
        override fun onSetFailure(p0: String?) { Log.e(TAG, "SDP set failure: $p0") }
    }
}