package com.tbtrapp.audio

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.util.Base64
import android.util.Log
import java.io.File
import java.util.UUID

class VoiceRecorder(private val context: Context) {

    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null
    private var startTime: Long = 0L

    companion object {
        // RTDB nodes shouldn't hold huge blobs — cap raw audio around ~1MB
        // (~1.4MB once base64-encoded), roughly 40-60s of AAC voice.
        private const val MAX_AUDIO_BYTES = 1_000_000

        // getMaxAmplitude()'s theoretical ceiling is 32767 (16-bit PCM), but
        // normal speech rarely gets anywhere near that — normalizing against
        // the true max makes the waveform look almost flat. 12000 is a
        // practical "loud speech" ceiling that gives visually responsive
        // bars; coerced to 1f above so it just clips on genuinely loud input.
        private const val MAX_MEANINGFUL_AMPLITUDE = 12000f
    }

    fun startRecording(): File {
        val fileName = "voice_${UUID.randomUUID()}.m4a"
        val file = File(context.cacheDir, fileName)
        outputFile = file

        val mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }

        mediaRecorder.apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setAudioEncodingBitRate(96000)
            setAudioSamplingRate(44100)
            setOutputFile(file.absolutePath)
            prepare()
            start()
        }

        recorder = mediaRecorder
        startTime = System.currentTimeMillis()
        return file
    }

    fun pauseRecording() {
        recorder?.pause()
    }

    fun resumeRecording() {
        recorder?.resume()
    }

    /**
     * Current input amplitude, normalized to 0f..1f, for driving a live
     * waveform while recording. MediaRecorder.getMaxAmplitude() reports the
     * peak since the last call and resets it, so this is meant to be polled
     * on a timer (e.g. every ~100ms) — don't call it more than once per tick.
     * Returns 0f when not actively recording (paused counts as not amplitude-
     * producing, since MediaRecorder still returns whatever was buffered).
     */
    fun currentAmplitude(): Float {
        val amplitude = try {
            recorder?.maxAmplitude ?: 0
        } catch (_: IllegalStateException) {
            // Thrown if called between prepare()/start() and an active
            // recording state, e.g. right after pause() on some OEMs.
            0
        }
        return (amplitude / MAX_MEANINGFUL_AMPLITUDE).coerceIn(0f, 1f)
    }

    /** Stops recording and returns duration in whole seconds (minimum 1). */
    fun stopRecording(): Int {
        val elapsedSeconds = ((System.currentTimeMillis() - startTime) / 1000).toInt().coerceAtLeast(1)
        try {
            recorder?.apply {
                stop()
                release()
            }
        } catch (e: Exception) {
            Log.e("VoiceRecorder", "stop() failed: ${e.message}")
        }
        recorder = null
        return elapsedSeconds
    }

    fun cancelRecording() {
        try {
            recorder?.apply {
                stop()
                release()
            }
        } catch (_: Exception) {
        }
        recorder = null
        outputFile?.delete()
        outputFile = null
    }

    /**
     * Reads the recorded file and base64-encodes it for storage directly in
     * Realtime Database — no Firebase Storage involved. Deletes the temp
     * file afterward either way. onFailure fires if missing or too large.
     */
    fun encodeRecordingToBase64(
        onSuccess: (String) -> Unit,
        onFailure: (Exception) -> Unit
    ) {
        val file = outputFile
        if (file == null || !file.exists()) {
            onFailure(IllegalStateException("No recording file found"))
            return
        }
        if (file.length() > MAX_AUDIO_BYTES) {
            file.delete()
            outputFile = null
            onFailure(IllegalStateException("Recording too long — keep voice notes under about 45 seconds"))
            return
        }
        try {
            val bytes = file.readBytes()
            val base64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
            file.delete()
            outputFile = null
            onSuccess(base64)
        } catch (e: Exception) {
            onFailure(e)
        }
    }
}