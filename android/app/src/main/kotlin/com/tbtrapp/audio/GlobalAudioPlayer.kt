package com.tbtrapp.audio

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.ContextCompat

data class NowPlaying(val id: String, val title: String, val filePath: String)

object GlobalAudioPlayer {

    val nowPlaying = mutableStateOf<NowPlaying?>(null)
    val isPlaying = mutableStateOf(false)
    val positionMs = mutableIntStateOf(0)
    val durationMs = mutableIntStateOf(0)

    private var onCompleteCallback: (() -> Unit)? = null

    // ── Position throttling (works on ALL API levels) ──────────────
    private val handler = Handler(Looper.getMainLooper())
    private var pendingPosition = 0
    private var isPostPending = false  // ← replaces hasCallbacks()

    private val positionRunnable = Runnable {
        positionMs.intValue = pendingPosition
        isPostPending = false
    }

    fun setPosition(ms: Int) {
        pendingPosition = ms
        if (!isPostPending) {
            isPostPending = true
            handler.postDelayed(positionRunnable, 250)
        }
    }

    // ── Public API ──────────────────────────────────────────────────

    fun play(
        context: Context,
        id: String,
        title: String,
        filePath: String,
        onComplete: (() -> Unit)? = null
    ) {
        onCompleteCallback = onComplete
        nowPlaying.value = NowPlaying(id, title, filePath)
        positionMs.intValue = 0
        durationMs.intValue = 0
        pendingPosition = 0
        isPostPending = false
        handler.removeCallbacks(positionRunnable)

        val intent = Intent(context, AudioPlaybackService::class.java).apply {
            action = AudioPlaybackService.ACTION_PLAY
            putExtra(AudioPlaybackService.EXTRA_ID, id)
            putExtra(AudioPlaybackService.EXTRA_TITLE, title)
            putExtra(AudioPlaybackService.EXTRA_PATH, filePath)
        }
        ContextCompat.startForegroundService(context, intent)
    }

    fun pause(context: Context) {
        sendAction(context, AudioPlaybackService.ACTION_PAUSE)
    }

    fun resume(context: Context) {
        sendAction(context, AudioPlaybackService.ACTION_RESUME)
    }

    fun seekTo(context: Context, ms: Int) {
        val intent = Intent(context, AudioPlaybackService::class.java).apply {
            action = AudioPlaybackService.ACTION_SEEK
            putExtra(AudioPlaybackService.EXTRA_SEEK_MS, ms)
        }
        context.startService(intent)

        pendingPosition = ms
        positionMs.intValue = ms
        isPostPending = false
        handler.removeCallbacks(positionRunnable)
    }

    fun isSameItem(id: String): Boolean = nowPlaying.value?.id == id

    fun stop(context: Context) {
        sendAction(context, AudioPlaybackService.ACTION_STOP)
        handler.removeCallbacks(positionRunnable)
        isPostPending = false
        nowPlaying.value = null
        isPlaying.value = false
        positionMs.intValue = 0
        durationMs.intValue = 0
        pendingPosition = 0
    }

    fun notifyComplete() {
        isPlaying.value = false
        onCompleteCallback?.invoke()
    }

    private fun sendAction(context: Context, action: String) {
        val intent = Intent(context, AudioPlaybackService::class.java).apply {
            this.action = action
        }
        context.startService(intent)
    }
}