import 'package:flutter_webrtc/flutter_webrtc.dart';

class CallConnectionRegistry {
  static final Map<String, RTCPeerConnection> _connections = {};
  static final Map<String, VoidCallback> _onActiveCallbacks = {};

  static void put(String callId, RTCPeerConnection connection) {
    _connections[callId] = connection;
  }

  static RTCPeerConnection? get(String callId) => _connections[callId];

  static void remove(String callId) {
    _connections.remove(callId);
    _onActiveCallbacks.remove(callId);
  }

  static void markActive(String callId) {
    // Dart has no Telecom Connection.setActive() equivalent.
    // This is a hook for any custom "call became active" logic.
    _onActiveCallbacks[callId]?.call();
  }

  static void onActive(String callId, VoidCallback callback) {
    _onActiveCallbacks[callId] = callback;
  }

  static void disconnect(String callId) {
    final pc = _connections[callId];
    if (pc != null) {
      pc.close();
    }
    remove(callId);
  }

  static void clear() {
    for (final pc in _connections.values) {
      pc.close();
    }
    _connections.clear();
    _onActiveCallbacks.clear();
  }
}