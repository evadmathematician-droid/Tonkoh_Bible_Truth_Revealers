import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../navigation/call_navigator.dart';
import 'incoming_call_manager.dart';

/// Bridges the native full-screen incoming-call notification
/// (`CallNotificationServiceExtension.kt` → `MainActivity.kt`, method channel
/// `com.tbtrapp/calls`) into the Flutter call UI.
///
/// This is the killed / backgrounded path: the OneSignal call push wakes the
/// process, the native extension posts a `CATEGORY_CALL` full-screen
/// notification, and tapping it (or its Accept button) launches
/// `MainActivity` with call extras. Here we turn those extras into the same
/// [IncomingCallManager] flow the in-app RTDB listener uses, so ringing +
/// the incoming-call screen behave identically however the call arrived.
///
/// Android only; a no-op elsewhere (the channel simply isn't registered).
class NativeCallBridge {
  static const MethodChannel _channel = MethodChannel('com.tbtrapp/calls');
  static bool _initialized = false;

  /// Call once in `main()`, after `CallNotifications.init()` and before
  /// `runApp()`, so a cold start triggered by the notification isn't missed.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler(_onMethodCall);

    // Cold start: the engine (and this handler) didn't exist when the intent
    // arrived — pull any pending call extras now.
    try {
      final initial =
          await _channel.invokeMethod<Map<Object?, Object?>>('getInitialCallExtras');
      if (initial != null) _handleExtras(_stringMap(initial));
    } on PlatformException catch (e) {
      debugPrint('NativeCallBridge: getInitialCallExtras failed: ${e.message}');
    } on MissingPluginException {
      // Not Android / channel not registered — fine.
    }
  }

  static Future<void> _onMethodCall(MethodCall call) async {
    if (call.method != 'onCallIntent') return;
    final args = call.arguments;
    if (args is Map) _handleExtras(_stringMap(args));
  }

  static Map<String, String?> _stringMap(Map<Object?, Object?> raw) =>
      raw.map((key, value) => MapEntry(key as String, value as String?));

  static void _handleExtras(Map<String, String?> extras) {
    final action = extras['callAction'];
    final callId = extras['callId'];
    if (callId == null || callId.isEmpty) return;

    final callerId = extras['callerId'] ?? '';
    final callerName = extras['callerName'] ?? 'Unknown';
    final callerPhoto = extras['callerPhoto'] ?? '';
    final chatId = extras['chatId'] ?? '';
    final callType = extras['callType'] ?? 'audio';

    switch (action) {
      case 'incoming':
        // Show the ringing screen + start ringtone/vibration. Idempotent —
        // IncomingCallManager ignores a call it's already handling, so this
        // is safe even if the RTDB listener also fires for the same call.
        IncomingCallManager.instance.handleIncomingCall(
          callId: callId,
          callerId: callerId,
          callerName: callerName,
          callerPhoto: callerPhoto,
          chatId: chatId,
          callType: callType,
        );
        break;
      case 'accept':
        // Cold start: IncomingCallManager has no state for this call in a
        // fresh process, so acceptCall() would no-op and ACCEPTED would
        // never reach the caller. Write it directly (same as
        // IncomingCallScreen._accept's fallback), tear down any ringing that
        // did start, then go straight to the in-call screen.
        IncomingCallManager.instance.acceptCall();
        FirebaseDatabase.instance
            .ref('calls')
            .child(callId)
            .child('state')
            .set('ACCEPTED');
        CallNavigator.replaceWithOngoingCall(
          callId: callId,
          callType: callType,
          isCaller: false,
          peerName: callerName,
        );
        break;
    }
  }
}
