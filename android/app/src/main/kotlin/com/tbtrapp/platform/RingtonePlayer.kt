package com.tbtrapp.platform

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.util.Log

/**
 * Looping incoming-call ringtone for the "app process alive, screen locked or
 * backgrounded" case (a killed process rings via the OneSignal push
 * notification instead, which this class does not touch).
 *
 * Why this exists: the incoming-call notification was relying on
 * `FLAG_INSISTENT` + a raw-resource sound to loop a ringtone. On several of
 * the OEM builds this app runs on (Infinix / Transsion in particular) an
 * insistent notification sound simply does not play — the device vibrated for
 * the full 40 s but stayed silent. A dedicated MediaPlayer on the ringtone
 * stream is what actual VoIP apps use, and it is fully under our control:
 * start it when the call arrives, stop it on answer / decline / hang-up /
 * timeout.
 *
 * Audio routing:
 *  * `USAGE_NOTIFICATION_RINGTONE` + `CONTENT_TYPE_SONIFICATION` → the system
 *    plays it on the ring stream, so it follows ring volume (not media
 *    volume) and ducks other audio like a real ringtone.
 *  * Ringer mode is checked explicitly: on SILENT / VIBRATE we play nothing
 *    (the Dart side is looping the vibration separately), matching what the
 *    user expects when they've silenced the phone.
 *  * Source is the bundled `res/raw/ringtone`; if that fails to load we fall
 *    back to the device's actual default ringtone URI so there is always
 *    *some* ring.
 */
class RingtonePlayer(private val context: Context) {

    private var player: MediaPlayer? = null

    @Synchronized
    fun start() {
        if (player != null) {
            Log.d(TAG, "start() ignored — already ringing")
            return
        }

        val audioManager =
            context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val ringerMode = audioManager?.ringerMode ?: AudioManager.RINGER_MODE_NORMAL
        if (ringerMode != AudioManager.RINGER_MODE_NORMAL) {
            Log.d(TAG, "start() — ringer mode is $ringerMode (silent/vibrate), not playing audio")
            return
        }

        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        val started = tryStart(bundledRingtoneUri(), attributes) ||
            tryStart(
                RingtoneManager.getActualDefaultRingtoneUri(
                    context, RingtoneManager.TYPE_RINGTONE
                ),
                attributes
            )

        if (!started) {
            Log.w(TAG, "start() — could not start any ringtone source")
        }
    }

    private fun tryStart(uri: Uri?, attributes: AudioAttributes): Boolean {
        if (uri == null) return false
        return try {
            val mp = MediaPlayer()
            mp.setAudioAttributes(attributes)
            mp.setDataSource(context, uri)
            mp.isLooping = true
            mp.setOnErrorListener { _, what, extra ->
                Log.w(TAG, "MediaPlayer error what=$what extra=$extra")
                true
            }
            mp.prepare()
            mp.start()
            player = mp
            Log.d(TAG, "ringtone playing from $uri")
            true
        } catch (e: Exception) {
            Log.w(TAG, "failed to start ringtone from $uri: ${e.message}")
            false
        }
    }

    @Synchronized
    fun stop() {
        val mp = player ?: return
        player = null
        try {
            if (mp.isPlaying) mp.stop()
        } catch (e: Exception) {
            Log.w(TAG, "stop() — mp.stop() threw: ${e.message}")
        }
        try {
            mp.reset()
            mp.release()
        } catch (e: Exception) {
            Log.w(TAG, "stop() — release threw: ${e.message}")
        }
        Log.d(TAG, "ringtone stopped")
    }

    private fun bundledRingtoneUri(): Uri? {
        val resId = context.resources.getIdentifier(
            "ringtone", "raw", context.packageName
        )
        if (resId == 0) return null
        return Uri.parse("android.resource://${context.packageName}/$resId")
    }

    companion object {
        private const val TAG = "RingtonePlayer"

        @Volatile
        private var sharedPlayer: RingtonePlayer? = null

        /**
         * The one player for the whole process, shared by Flutter's
         * `startRingtone` and the native IncomingRingService, so the two
         * can never ring on top of each other.
         */
        fun shared(context: Context): RingtonePlayer =
            sharedPlayer ?: synchronized(this) {
                sharedPlayer ?: RingtonePlayer(context.applicationContext)
                    .also { sharedPlayer = it }
            }
    }
}
