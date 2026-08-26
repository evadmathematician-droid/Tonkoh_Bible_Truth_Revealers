import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class CallConnectionMonitor {
  final int timeoutMs;
  final VoidCallback onTimeout;

  Timer? _timer;
  bool _isConnected = false;
  bool _isCancelled = false;

  CallConnectionMonitor({
    this.timeoutMs = 30000,
    required this.onTimeout,
  });

  void start() {
    _isConnected = false;
    _isCancelled = false;
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: timeoutMs), () {
      if (!_isConnected && !_isCancelled) {
        debugPrint('CallConnectionMonitor: Connection timeout after ${timeoutMs}ms — forcing hangup');
        onTimeout();
      }
    });
  }

  void markConnected() {
    if (_isConnected) return;
    _isConnected = true;
    _timer?.cancel();
  }

  void cancel() {
    _isCancelled = true;
    _timer?.cancel();
  }

  void onPeerConnectionStateChange(RTCPeerConnectionState? state) {
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      markConnected();
    }
  }
}