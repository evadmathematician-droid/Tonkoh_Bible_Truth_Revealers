import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Starts/stops the native [CallForegroundService] that keeps the process
/// alive for the duration of an active call (so Android doesn't kill the
/// WebRTC connection when the call screen is backgrounded).
///
/// Android only; a no-op everywhere else. Started by [OngoingCallManager]
/// when a call connects and stopped on hang-up.
class CallForegroundService {
  CallForegroundService._();

  static const MethodChannel _channel = MethodChannel('com.tbtrapp/calls');
  static bool _running = false;

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static Future<void> start({
    required String callType,
    required String peerName,
  }) async {
    if (!_supported || _running) return;
    _running = true;
    try {
      await _channel.invokeMethod('startCallForeground', {
        'callType': callType,
        'peerName': peerName,
      });
    } catch (e) {
      debugPrint('CallForegroundService.start failed: $e');
    }
  }

  static Future<void> stop() async {
    if (!_supported || !_running) return;
    _running = false;
    try {
      await _channel.invokeMethod('stopCallForeground');
    } catch (e) {
      debugPrint('CallForegroundService.stop failed: $e');
    }
  }
}
