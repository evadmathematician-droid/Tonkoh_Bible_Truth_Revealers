package com.tbtrapp.audio

import android.R
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class AudioPlaybackService : Service() {

    companion object {
        const val CHANNEL_ID = "audio_playback_channel"
        const val NOTIFICATION_ID = 1001

        const val ACTION_PLAY = "com.tbtrapp.audio.PLAY"
        const val ACTION_PAUSE = "com.tbtrapp.audio.PAUSE"
        const val ACTION_RESUME = "com.tbtrapp.audio.RESUME"
        const val ACTION_STOP = "com.tbtrapp.audio.STOP"
        const val ACTION_SEEK = "com.tbtrapp.audio.SEEK"

        const val EXTRA_ID = "extra_id"
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_PATH = "extra_path"
        const val EXTRA_SEEK_MS = "extra_seek_ms"
    }

    private var player: MediaPlayer? = null
    private lateinit var mediaSession: MediaSessionCompat
    private var progressLoop: Job? = null
    private val serviceScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private var currentId: String = ""
    private var currentTitle: String = ""
    private var currentPath: String = ""

    private var pendingSeekMs: Int? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        mediaSession = MediaSessionCompat(this, "AudioPlaybackService").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = resume()
                override fun onPause() = pause()
                override fun onStop() = stopPlayback()
                override fun onSeekTo(pos: Long) = seek(pos.toInt())
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY -> {
                val id = intent.getStringExtra(EXTRA_ID) ?: return START_NOT_STICKY
                val title = intent.getStringExtra(EXTRA_TITLE) ?: ""
                val path = intent.getStringExtra(EXTRA_PATH) ?: return START_NOT_STICKY
                startPlayback(id, title, path)
            }
            ACTION_PAUSE -> pause()
            ACTION_RESUME -> resume()
            ACTION_STOP -> stopPlayback()
            ACTION_SEEK -> seek(intent.getIntExtra(EXTRA_SEEK_MS, 0))
        }
        return START_STICKY
    }

    private fun startPlayback(id: String, title: String, path: String) {
        release()
        currentId = id
        currentTitle = title
        currentPath = path

        player = MediaPlayer().apply {
            setDataSource(applicationContext, Uri.parse(path))
            setOnPreparedListener {
                it.start()
                pendingSeekMs?.let { seekMs ->
                    it.seekTo(seekMs)
                    GlobalAudioPlayer.setPosition(seekMs)  // ← throttled
                    pendingSeekMs = null
                }
                GlobalAudioPlayer.isPlaying.value = true
                GlobalAudioPlayer.durationMs.intValue = it.duration  // ← intValue
                startForeground(NOTIFICATION_ID, buildNotification(true))
                startProgressLoop()
                updatePlaybackState(PlaybackStateCompat.STATE_PLAYING)
            }
            setOnCompletionListener {
                handleCompletion()
            }
            prepareAsync()
        }
    }

    private fun pause() {
        player?.pause()
        GlobalAudioPlayer.isPlaying.value = false
        updatePlaybackState(PlaybackStateCompat.STATE_PAUSED)
        updateNotification(false)
    }

    private fun resume() {
        val existing = player
        if (existing == null) {
            if (currentPath.isNotBlank()) {
                startPlayback(currentId, currentTitle, currentPath)
            }
            return
        }
        existing.start()
        GlobalAudioPlayer.isPlaying.value = true
        updatePlaybackState(PlaybackStateCompat.STATE_PLAYING)
        updateNotification(true)
    }

    private fun seek(ms: Int) {
        val existing = player
        if (existing == null) {
            if (currentPath.isNotBlank()) {
                pendingSeekMs = ms
                startPlayback(currentId, currentTitle, currentPath)
            }
            return
        }
        existing.seekTo(ms)
        GlobalAudioPlayer.setPosition(ms)  // ← throttled
    }

    private fun stopPlayback() {
        release()
        currentPath = ""
        GlobalAudioPlayer.isPlaying.value = false
        GlobalAudioPlayer.positionMs.intValue = 0   // ← intValue
        GlobalAudioPlayer.durationMs.intValue = 0   // ← intValue
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun handleCompletion() {
        progressLoop?.cancel()
        progressLoop = null
        player?.release()
        player = null

        GlobalAudioPlayer.notifyComplete()
        GlobalAudioPlayer.positionMs.intValue = 0   // ← intValue

        updatePlaybackState(PlaybackStateCompat.STATE_PAUSED)
        if (player == null) {
            updateNotification(false)
        }
    }

    private fun startProgressLoop() {
        progressLoop?.cancel()
        progressLoop = serviceScope.launch {
            while (isActive) {
                player?.let {
                    if (it.isPlaying) {
                        GlobalAudioPlayer.setPosition(it.currentPosition)  // ← throttled
                    }
                }
                delay(500)
            }
        }
    }

    private fun buildNotification(isPlaying: Boolean): Notification {
        val playPauseAction = if (isPlaying) {
            NotificationCompat.Action(
                R.drawable.ic_media_pause,
                "Pause",
                servicePendingIntent(ACTION_PAUSE)
            )
        } else {
            NotificationCompat.Action(
                R.drawable.ic_media_play,
                "Play",
                servicePendingIntent(ACTION_RESUME)
            )
        }
        val stopAction = NotificationCompat.Action(
            R.drawable.ic_menu_close_clear_cancel,
            "Stop",
            servicePendingIntent(ACTION_STOP)
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(currentTitle)
            .setSmallIcon(R.drawable.ic_media_play)
            .setOnlyAlertOnce(true)
            .setOngoing(isPlaying)
            .addAction(playPauseAction)
            .addAction(stopAction)
            .setStyle(
                MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(0, 1)
            )
            .build()
    }

    private fun updateNotification(isPlaying: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(isPlaying))
    }

    private fun servicePendingIntent(action: String): PendingIntent {
        val intent = Intent(this, AudioPlaybackService::class.java).apply {
            this.action = action
        }
        return PendingIntent.getService(
            this,
            action.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun updatePlaybackState(state: Int) {
        val playbackState = PlaybackStateCompat.Builder()
            .setActions(
                PlaybackStateCompat.ACTION_PLAY or
                        PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_STOP or
                        PlaybackStateCompat.ACTION_SEEK_TO
            )
            .setState(state, player?.currentPosition?.toLong() ?: 0L, 1f)
            .build()
        mediaSession.setPlaybackState(playbackState)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Playback",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun release() {
        progressLoop?.cancel()
        progressLoop = null
        player?.release()
        player = null
    }

    override fun onDestroy() {
        release()
        mediaSession.release()
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}