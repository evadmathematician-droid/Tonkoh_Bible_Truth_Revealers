package com.tbtrapp

import android.os.Bundle
import androidx.core.view.WindowCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity (from just_audio_background's audio_service
// dependency) extends FlutterActivity itself and only adds the shared
// FlutterEngine wiring audio_service needs to run playback in the
// background — required for the audio-playback notification (play/pause/
// progress) to work. See android/app/src/main/AndroidManifest.xml for the
// matching service/receiver additions.
class MainActivity : AudioServiceActivity() {
    // Backs CallPlatform.moveTaskToBack() (lib/calls/call_platform.dart),
    // used by OngoingCallScreen so pressing back during a call backgrounds
    // the app (keeping the call's foreground service alive) instead of
    // exiting it via the old SystemNavigator.pop() fallback.
    private val callsChannel = "com.tbtrapp/calls"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 15+ (targetSdk 35, which this app already targets) makes
        // the app edge-to-edge by default — the system bars go transparent
        // whether or not the app is ready for it. Without this call, the
        // Flutter root view still lays out as if the bars were opaque, so
        // content just stops short of the real screen edges instead of
        // actually drawing behind them; individual screens rely on
        // SafeArea/MediaQuery.viewPadding to avoid being obscured once this
        // is on. Using WindowCompat rather than the newer
        // androidx.activity.enableEdgeToEdge() because FlutterActivity
        // (which AudioServiceActivity extends) is a plain
        // android.app.Activity, not a androidx.activity.ComponentActivity —
        // enableEdgeToEdge() isn't callable on it.
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, callsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveTaskToBack" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
