import 'package:flutter/services.dart';

class CallPlatform {
  static const MethodChannel _channel = MethodChannel('com.tbtrapp/calls');

  static Future<void> moveTaskToBack() async {
    try {
      await _channel.invokeMethod('moveTaskToBack');
    } catch (_) {
      // Fallback on iOS or if channel isn't wired yet
      SystemNavigator.pop();
    }
  }
}