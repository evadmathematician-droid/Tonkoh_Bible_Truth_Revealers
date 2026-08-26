package com.tbtrapp.calls

import android.os.Handler
import android.os.Looper
import android.util.Log
import org.webrtc.PeerConnection

/**
 * Independent safety net. If the peer connection never reaches
 * CONNECTED within [timeoutMs], [onTimeout] is fired.
 * This prevents getting stuck forever on "Connecting…" when the
 * caller crashes, TURN is broken, or Firebase signaling races.
 */
class CallConnectionMonitor(
    private val timeoutMs: Long = 30000L,
    private val onTimeout: () -> Unit
) {
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var isConnected = false
    @Volatile private var isCancelled = false

    private val timeoutRunnable = Runnable {
        if (!isConnected && !isCancelled) {
            Log.w("CallConnectionMonitor", "Connection timeout after ${timeoutMs}ms — forcing hangup")
            onTimeout()
        }
    }

    /** Start the timer. Call this when the call UI opens. */
    fun start() {
        isConnected = false
        isCancelled = false
        handler.postDelayed(timeoutRunnable, timeoutMs)
    }

    /** Call from PeerConnection.Observer.onConnectionStateChange when CONNECTED. */
    fun markConnected() {
        if (isConnected) return
        isConnected = true
        handler.removeCallbacks(timeoutRunnable)
    }

    /** Call this in onDestroy() / hangUp() to avoid leaking the handler. */
    fun cancel() {
        isCancelled = true
        handler.removeCallbacks(timeoutRunnable)
    }

    /** Convenience wrapper. */
    fun onPeerConnectionStateChange(state: PeerConnection.PeerConnectionState?) {
        when (state) {
            PeerConnection.PeerConnectionState.CONNECTED -> markConnected()
            else -> { /* wait */ }
        }
    }
}