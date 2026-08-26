package com.tbtrapp.calls

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Replaces one-shot ToneGenerator.TONE_SUP_RINGTONE.
 * The built-in tone only cycles ~3 times then stops. This manager
 * restarts it every 5.5 s until stop() is called.
 *
 * FIX: was constructed on AudioManager.STREAM_VOICE_CALL (stream index 0).
 * That stream is only routed to a speaker/earpiece when the device's audio
 * mode is MODE_IN_CALL — i.e. a real telephony call registered with
 * TelecomManager. This app is WebRTC-based and never enters MODE_IN_CALL
 * (see WebRtcClient.setupLocalMedia(), which uses MODE_IN_COMMUNICATION
 * instead), so STREAM_VOICE_CALL had nowhere audible to route to: the tone
 * was starting/stopping right on schedule but was effectively silent.
 *
 * STREAM_MUSIC routes normally through the speaker/earpiece regardless of
 * audio mode, which is the same approach other VoIP apps (WhatsApp,
 * Signal, etc.) use for outgoing-call ringback.
 */
class RingbackManager {

    private var toneGenerator: ToneGenerator? = null
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var isPlaying = false

    private val loopRunnable = object : Runnable {
        override fun run() {
            if (!isPlaying) return
            try {
                // 4000 ms tone + 1500 ms pause = realistic ringback cadence
                toneGenerator?.startTone(ToneGenerator.TONE_SUP_RINGTONE, 4000)
                handler.postDelayed(this, 5500)
            } catch (e: Exception) {
                Log.e("RingbackManager", "Tone error", e)
            }
        }
    }

    fun start() {
        if (isPlaying) return
        isPlaying = true
        // Max ToneGenerator volume (0-100) — STREAM_MUSIC has its own
        // system volume control, so we don't need to attenuate here the
        // way the old STREAM_VOICE_CALL constructor did.
        toneGenerator = ToneGenerator(AudioManager.STREAM_MUSIC, 100)
        handler.post(loopRunnable)
    }

    fun stop() {
        isPlaying = false
        handler.removeCallbacks(loopRunnable)
        try { toneGenerator?.stopTone() } catch (_: Exception) {}
        try { toneGenerator?.release() } catch (_: Exception) {}
        toneGenerator = null
    }
}