import 'package:flutter/services.dart';
import 'call_notifications.dart';

/// Target path: lib/calls/native_call_bridge.dart (adjust to match your
/// project's actual lib/ layout — this sits alongside CallNotifications,
/// IncomingCallManager, etc.)
///
/// Reads the call extras that CallService.kt attaches to MainActivity's
/// launch/new intent (see MainActivity.kt's `com.tbtrapp/calls` channel).
///
/// Only the "accept" case needs action here: when the user taps Accept on
/// the native full-screen notification, CallService already set Firebase
/// state to ACCEPTED and launched MainActivity — this bridge's job is to
/// tell Flutter about it so OngoingCallManager actually starts. It does that
/// by replaying the exact same CallNotificationAction your existing UI
/// already handles when Accept is tapped on the LOCAL (in-app) notification,
/// so there's one single accept code path, not two.
///
/// The "view" case (user tapped the notification body, not Accept) needs no
/// special handling — the native notification's own Accept/Decline buttons
/// keep working regardless, and bringing the app to the foreground is all
/// that's needed for anything else already listening to Firebase/RTDB state.
class NativeCallBridge {
  static const MethodChannel _channel = MethodChannel('com.tbtrapp/calls');
  static bool _initialized = false;

  /// Call once, early in main() — after CallNotifications.init() and before
  /// runApp() — so a cold start triggered by tapping Accept isn't missed.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler(_onMethodCall);

    // Cold start: the app process didn't exist yet, so there was no channel
    // for CallService's launch intent to push through — ask for it once now
    // that the engine (and this handler) is up.
    try {
      final initial = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getInitialCallExtras',
      );
      if (initial != null) _handleExtras(_stringMap(initial));
    } on PlatformException catch (e) {
      // Non-fatal — just means there was no pending call-launch intent.
      // ignore: avoid_print
      print('NativeCallBridge: getInitialCallExtras failed: ${e.message}');
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
    final callAction = extras['callAction'];
    final callId = extras['callId'];
    final callType = extras['callType'];
    final callerName = extras['callerName'];

    if (callId == null || callId.isEmpty) return;

    if (callAction == 'accept') {
      CallNotifications.emitAction(
        CallNotificationAction(
          action: 'accept',
          callId: callId,
          callType: callType,
          callerName: callerName,
        ),
      );
    }
    // callAction == 'view' (or unset): nothing else to do — see class doc.
  }
}