import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin Dart handle over the native looping incoming-call ringtone
/// (`RingtonePlayer.kt`, method channel `com.tbtrapp/ringtone`).
///
/// Background: the incoming-call *notification* was supposed to loop a
/// ringtone via `FLAG_INSISTENT`, but on the Transsion/Infinix builds this
/// app targets that never produced sound — the phone vibrated for the full
/// ~40 s and stayed silent. The native player rings on the phone's ring
/// stream (follows ring volume, honours silent/vibrate mode), which is what
/// a real call does, and is started/stopped explicitly by
/// [IncomingCallManager].
///
/// Android only. Every call is a best-effort no-op elsewhere (and if the
/// channel isn't registered, e.g. on iOS/web/desktop).
class IncomingRingtone {
  IncomingRingtone._();
  static final IncomingRingtone instance = IncomingRingtone._();

  static const MethodChannel _channel = MethodChannel('com.tbtrapp/ringtone');

  bool _ringing = false;

  Future<void> start() async {
    if (_ringing) return;
    _ringing = true;
    try {
      await _channel.invokeMethod('startRingtone');
      debugPrint('IncomingRingtone: start requested');
    } catch (e) {
      // MissingPluginException on non-Android, or a native failure — the
      // call still works, it's just silent (vibration keeps going).
      debugPrint('IncomingRingtone: start failed: $e');
    }
  }

  Future<void> stop() async {
    if (!_ringing) return;
    _ringing = false;
    try {
      await _channel.invokeMethod('stopRingtone');
      debugPrint('IncomingRingtone: stop requested');
    } catch (e) {
      debugPrint('IncomingRingtone: stop failed: $e');
    }
  }
}
