package com.tbtrapp.calls

import android.Manifest
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.firebase.database.*
import com.tbtrapp.call.IceCandidateModel
import com.tbtrapp.call.WebRtcClient
import kotlinx.coroutines.*
import org.webrtc.EglBase
import org.webrtc.PeerConnection
import org.webrtc.VideoTrack


class OngoingCallService : Service() {

    companion object {
        private const val TAG = "OngoingCallService"

        const val ACTION_START = "com.tbtrapp.calls.action.START"
        const val ACTION_END = "com.tbtrapp.calls.action.END"

        private const val EXTRA_CALL_ID = "call_id"
        private const val EXTRA_CALL_TYPE = "call_type"
        private const val EXTRA_IS_CALLER = "is_caller"
        private const val EXTRA_PEER_NAME = "peer_name"
        private const val EXTRA_CAMERA_GRANTED = "camera_granted"

        fun buildStartIntent(
            context: Context,
            callId: String,
            isCaller: Boolean,
            callType: String,
            peerName: String,
            cameraGranted: Boolean = false
        ): Intent = Intent(context, OngoingCallService::class.java).apply {
            action = ACTION_START
            putExtra(EXTRA_CALL_ID, callId)
            putExtra(EXTRA_CALL_TYPE, callType)
            putExtra(EXTRA_IS_CALLER, isCaller)
            putExtra(EXTRA_PEER_NAME, peerName)
            putExtra(EXTRA_CAMERA_GRANTED, cameraGranted)
        }

        fun buildEndIntent(context: Context): Intent =
            Intent(context, OngoingCallService::class.java).apply { action = ACTION_END }
    }

    interface CallListener {
        fun onConnectionStateChanged(status: String)
        fun onRemoteVideoTrack(track: VideoTrack)
        fun onCallEnded()
    }

    inner class LocalBinder : Binder() {
        fun getService(): OngoingCallService = this@OngoingCallService
    }
    private val binder = LocalBinder()

    private var listener: CallListener? = null
    fun setListener(l: CallListener?) { listener = l }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    lateinit var callId: String
        private set
    lateinit var callType: String
        private set
    var isCaller: Boolean = false
        private set
    private var peerName: String = ""
    private var lastStatusText: String = "Connecting…"

    private lateinit var eglBase: EglBase
    lateinit var webRtcClient: WebRtcClient
        private set

    // ---- Bind/start-order race fix ----
    //
    // startCallService() in the Activity fires startForegroundService() and
    // bindService() back to back. Android gives no ordering guarantee between
    // onStartCommand() (which is what actually constructs `webRtcClient` inside
    // initCall()) and onServiceConnected() firing on the bound client. If the
    // bind wins that race, the old code's onServiceConnected -> attachRenderers()
    // read `webRtcClient` while it was still unassigned, throwing
    // UninitializedPropertyAccessException.
    //
    // Fix: the service now explicitly announces readiness via `runWhenReady`
    // instead of the Activity assuming it based on bind success. Callers get
    // called back immediately if already ready, or queued until markReady()
    // runs. Both onStartCommand and onServiceConnected happen on the main
    // thread here (serviceScope uses Dispatchers.Main.immediate and Service
    // callbacks are main-thread by default), so no extra locking is needed,
    // but the list is still guarded defensively.
    @Volatile private var serviceReady = false
    private val onReadyCallbacks = mutableListOf<() -> Unit>()

    private fun markReady() {
        val callbacks: List<() -> Unit>
        synchronized(onReadyCallbacks) {
            if (serviceReady) return
            serviceReady = true
            callbacks = onReadyCallbacks.toList()
            onReadyCallbacks.clear()
        }
        callbacks.forEach { it() }
    }

    /**
     * Runs [callback] once `webRtcClient` is guaranteed to be constructed.
     * Fires synchronously if the service is already ready; otherwise queues
     * it to run as soon as initCall() finishes constructing webRtcClient.
     * If the call has already ended, the callback is dropped — there's
     * nothing left to attach to.
     */
    fun runWhenReady(callback: () -> Unit) {
        synchronized(onReadyCallbacks) {
            if (hasEnded) return
            if (serviceReady) {
                // fall through to call outside the lock
            } else {
                onReadyCallbacks.add(callback)
                return
            }
        }
        callback()
    }
    // ------------------------------------

    @Volatile private var remoteDescriptionSet = false
    @Volatile private var hasEnded = false
    @Volatile private var isInitialized = false

    private val connectionMonitor = CallConnectionMonitor(timeoutMs = 30000L) {
        Log.w(TAG, "Monitor timeout — ending call")
        endCallInternal()
    }

    private var stateListener: ValueEventListener? = null
    private var offerListener: ValueEventListener? = null
    private var answerListener: ValueEventListener? = null
    private var callerCandidatesRef: DatabaseReference? = null
    private var calleeCandidatesRef: DatabaseReference? = null
    private var callerCandidatesListener: ChildEventListener? = null
    private var calleeCandidatesListener: ChildEventListener? = null

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        CallNotifications.createChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_END -> {
                endCallInternal()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                if (isInitialized) {
                    if (!startForegroundTyped()) {
                        endCallInternal()
                    }
                    return START_NOT_STICKY
                }
                val extraCallId = intent.getStringExtra(EXTRA_CALL_ID)
                if (extraCallId == null) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                callId = extraCallId
                callType = intent.getStringExtra(EXTRA_CALL_TYPE) ?: "audio"
                isCaller = intent.getBooleanExtra(EXTRA_IS_CALLER, false)
                peerName = intent.getStringExtra(EXTRA_PEER_NAME) ?: "Unknown"
                val cameraGranted = intent.getBooleanExtra(EXTRA_CAMERA_GRANTED, false)

                isInitialized = true
                // Notification goes up FIRST, before any WebRTC/Firebase setup —
                // so it appears the instant the call is accepted/placed, for both
                // audio and video calls alike.
                if (!startForegroundTyped()) {
                    // FIX: startForeground failing used to crash the whole service
                    // (uncaught SecurityException from the phoneCall type below).
                    // Now it's caught, and we tear the call down cleanly instead of
                    // taking the process down with it.
                    Log.e(TAG, "startForeground failed on call start — ending call")
                    hasEnded = true // nothing was set up yet, skip full teardown work
                    listener?.onCallEnded()
                    stopSelf()
                    return START_NOT_STICKY
                }
                registerNetworkCallback()
                initCall(cameraGranted)
            }
        }
        return START_NOT_STICKY
    }

    /**
     * FIX: dropped FOREGROUND_SERVICE_TYPE_PHONE_CALL for both audio and video.
     * That type requires the call to be registered through TelecomManager /
     * a self-managed ConnectionService — nothing in this app does that, so
     * requesting it throws a SecurityException at runtime regardless of manifest
     * permissions, for BOTH call types equally. microphone (+camera for video)
     * is what we actually use. Wrapped in try/catch so a failure here degrades
     * to ending the call instead of crashing the service.
     *
     * Returns true if the foreground promotion succeeded.
     */
    private fun startForegroundTyped(): Boolean {
        val notification = buildNotification()
        val isVideo = callType.equals("video", ignoreCase = true)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val type = if (isVideo) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                } else {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(CallNotifications.NOTIF_ID_ONGOING, notification, type)
            } else {
                startForeground(CallNotifications.NOTIF_ID_ONGOING, notification)
            }
            true
        } catch (e: SecurityException) {
            Log.e(TAG, "startForeground SecurityException: ${e.message}", e)
            false
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed: ${e.message}", e)
            false
        }
    }

    private fun buildNotification() = CallNotifications.buildOngoingCallNotification(
        this, callType, peerName, lastStatusText,
        PendingIntent.getService(
            this, 0, buildEndIntent(this),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    )

    private fun updateNotification() {
        val nm = getSystemService(android.app.NotificationManager::class.java)
        nm.notify(CallNotifications.NOTIF_ID_ONGOING, buildNotification())
    }

    private fun registerNetworkCallback() {
        connectivityManager = getSystemService(ConnectivityManager::class.java)
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.d(TAG, "Network back — resuming signaling")
                FirebaseDatabase.getInstance().goOnline()
                lastStatusText = "Reconnecting…"
                updateNotification()
            }
            override fun onLost(network: Network) {
                Log.w(TAG, "Network lost mid-call — call stays up, signaling will resume on reconnect")
                lastStatusText = "Waiting for network…"
                updateNotification()
            }
        }
        networkCallback = callback
        connectivityManager?.registerNetworkCallback(request, callback)
    }

    private fun initCall(cameraGranted: Boolean) {
        val callsRef = FirebaseDatabase.getInstance().getReference("calls").child(callId)
        callerCandidatesRef = callsRef.child("callerCandidates")
        calleeCandidatesRef = callsRef.child("calleeCandidates")

        eglBase = EglBase.create()
        webRtcClient = WebRtcClient(this, eglBase, object : WebRtcClient.Listener {
            override fun onLocalIceCandidate(candidate: IceCandidateModel) {
                val ref = if (isCaller) callerCandidatesRef else calleeCandidatesRef
                ref?.push()?.setValue(candidate)
                    ?.addOnFailureListener { Log.e(TAG, "Failed to write ICE candidate", it) }
            }
            override fun onRemoteVideoTrack(track: VideoTrack) {
                listener?.onRemoteVideoTrack(track)
            }
            override fun onConnectionStateChanged(state: PeerConnection.PeerConnectionState) {
                connectionMonitor.onPeerConnectionStateChange(state)
                lastStatusText = when (state) {
                    PeerConnection.PeerConnectionState.CONNECTED -> "Connected"
                    PeerConnection.PeerConnectionState.FAILED -> "Connection failed"
                    PeerConnection.PeerConnectionState.DISCONNECTED -> "Reconnecting…"
                    else -> "Connecting…"
                }
                updateNotification()
                listener?.onConnectionStateChanged(lastStatusText)
            }
        })

        // `webRtcClient` and `eglBase` are both fully constructed at this point
        // (WebRtcClient's constructor just stores references — it doesn't touch
        // the factory/camera/etc. yet). Mark ready now, synchronously, so any
        // bind that connects after this line — even one that raced ahead of the
        // rest of onStartCommand — sees a valid webRtcClient instead of an
        // uninitialized one. Anything queued in onReadyCallbacks before this
        // point runs immediately too.
        markReady()

        serviceScope.launch {
            webRtcClient.initFactory()

            // FIX: don't trust the boolean handed in from the Activity — re-check
            // the actual OS permission state right before we use the camera. The
            // Activity's snapshot can go stale (revoked mid-flow, process death/
            // recreate, race between grant callback and service start), and when
            // it does, silently falling back to audio-only is the wrong failure
            // mode for a video call. `cameraGranted` param is now only used as a
            // hint for logging/diagnostics, not as the source of truth.
            val hasCameraPermission = ContextCompat.checkSelfPermission(
                this@OngoingCallService, Manifest.permission.CAMERA
            ) == PackageManager.PERMISSION_GRANTED

            if (callType.equals("video", ignoreCase = true) && cameraGranted != hasCameraPermission) {
                Log.w(TAG, "cameraGranted flag ($cameraGranted) disagreed with live permission check ($hasCameraPermission) — using live check")
            }

            val isVideo = callType.equals("video", ignoreCase = true) && hasCameraPermission
            val localStream = webRtcClient.setupLocalMedia(isVideo, null)
            val iceServers = webRtcClient.fetchIceServers()
            webRtcClient.createPeerConnection(localStream, iceServers)

            listenForRemoteHangup()
            if (isCaller) startAsCaller() else startAsCallee()
            connectionMonitor.start()
        }
    }

    private fun startAsCaller() {
        val callsRef = FirebaseDatabase.getInstance().getReference("calls").child(callId)
        webRtcClient.createOffer { sdp ->
            callsRef.child("offer").setValue(mapOf("sdp" to sdp, "type" to "offer"))

            answerListener = object : ValueEventListener {
                override fun onDataChange(snapshot: DataSnapshot) {
                    if (!snapshot.exists() || remoteDescriptionSet) return
                    val sdpStr = snapshot.child("sdp").getValue(String::class.java) ?: return
                    val typeStr = snapshot.child("type").getValue(String::class.java) ?: return
                    if (typeStr == "answer") {
                        remoteDescriptionSet = true
                        webRtcClient.setRemoteAnswer(sdpStr)
                    }
                }
                override fun onCancelled(error: DatabaseError) {}
            }
            callsRef.child("answer").addValueEventListener(answerListener!!)

            calleeCandidatesListener = object : ChildEventListener {
                override fun onChildAdded(snapshot: DataSnapshot, previousChildName: String?) {
                    snapshot.getValue(IceCandidateModel::class.java)?.let { webRtcClient.addRemoteIceCandidate(it) }
                }
                override fun onChildChanged(s: DataSnapshot, p: String?) {}
                override fun onChildRemoved(s: DataSnapshot) {}
                override fun onChildMoved(s: DataSnapshot, p: String?) {}
                override fun onCancelled(error: DatabaseError) {}
            }
            calleeCandidatesRef?.addChildEventListener(calleeCandidatesListener!!)
        }
    }

    private fun startAsCallee() {
        val callsRef = FirebaseDatabase.getInstance().getReference("calls").child(callId)
        offerListener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                if (!snapshot.exists() || remoteDescriptionSet) return
                val sdpStr = snapshot.child("sdp").getValue(String::class.java) ?: return
                val typeStr = snapshot.child("type").getValue(String::class.java) ?: return
                if (typeStr == "offer") {
                    remoteDescriptionSet = true
                    webRtcClient.setRemoteOffer(sdpStr) {
                        webRtcClient.createAnswer { answerSdp ->
                            callsRef.child("answer").setValue(mapOf("sdp" to answerSdp, "type" to "answer"))
                        }
                    }
                }
            }
            override fun onCancelled(error: DatabaseError) {}
        }
        callsRef.child("offer").addValueEventListener(offerListener!!)

        callerCandidatesListener = object : ChildEventListener {
            override fun onChildAdded(snapshot: DataSnapshot, previousChildName: String?) {
                snapshot.getValue(IceCandidateModel::class.java)?.let { webRtcClient.addRemoteIceCandidate(it) }
            }
            override fun onChildChanged(s: DataSnapshot, p: String?) {}
            override fun onChildRemoved(s: DataSnapshot) {}
            override fun onChildMoved(s: DataSnapshot, p: String?) {}
            override fun onCancelled(error: DatabaseError) {}
        }
        callerCandidatesRef?.addChildEventListener(callerCandidatesListener!!)
    }

    private fun listenForRemoteHangup() {
        val ref = FirebaseDatabase.getInstance().getReference("calls").child(callId).child("state")
        stateListener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val state = snapshot.getValue(String::class.java) ?: return
                if (state == "ENDED" || state == "DECLINED" || state == "MISSED") {
                    endCallInternal()
                }
            }
            override fun onCancelled(error: DatabaseError) {}
        }
        ref.addValueEventListener(stateListener!!)
    }

    fun endCall() = endCallInternal()

    private fun endCallInternal() {
        if (hasEnded) { stopSelfSafely(); return }
        hasEnded = true

        // Drop any queued ready-callbacks — there's nothing left to attach
        // renderers to once the call has ended.
        synchronized(onReadyCallbacks) { onReadyCallbacks.clear() }

        connectionMonitor.cancel()

        try {
            FirebaseDatabase.getInstance().getReference("calls").child(callId).child("state").setValue("ENDED")
        } catch (_: Exception) {}

        val callsRef = FirebaseDatabase.getInstance().getReference("calls").child(callId)
        try { stateListener?.let { callsRef.child("state").removeEventListener(it) } } catch (_: Exception) {}
        try { offerListener?.let { callsRef.child("offer").removeEventListener(it) } } catch (_: Exception) {}
        try { answerListener?.let { callsRef.child("answer").removeEventListener(it) } } catch (_: Exception) {}
        try { callerCandidatesListener?.let { callerCandidatesRef?.removeEventListener(it) } } catch (_: Exception) {}
        try { calleeCandidatesListener?.let { calleeCandidatesRef?.removeEventListener(it) } } catch (_: Exception) {}

        try {
            networkCallback?.let { connectivityManager?.unregisterNetworkCallback(it) }
        } catch (_: Exception) {}

        if (::webRtcClient.isInitialized) webRtcClient.endCall()
        try { if (::eglBase.isInitialized) eglBase.release() } catch (_: Exception) {}

        listener?.onCallEnded()
        stopSelfSafely()
    }

    private fun stopSelfSafely() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (!hasEnded) endCallInternal()
        serviceScope.cancel()
        super.onDestroy()
    }
}