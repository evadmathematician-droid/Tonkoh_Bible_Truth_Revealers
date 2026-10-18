import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../navigation/call_navigator.dart';
import 'incoming_share.dart';
import 'share_target_screen.dart';

/// Receives "Share → TBTR App" content from the native side
/// (ShareReceiverActivity → ShareInbox → MainActivity's com.tbtrapp/share
/// channel) and opens [ShareTargetScreen] for it.
///
/// A share that arrives before the user is signed in with a profile is held
/// until AuthGate reports ready, so it survives first-run setup. It's shown
/// on the root navigator, under ForceUpdateGate like everything else.
class ShareIntake {
  ShareIntake._();
  static final ShareIntake instance = ShareIntake._();

  static const _channel = MethodChannel('com.tbtrapp/share');

  IncomingShare? _pending;
  bool _ready = false;
  bool _started = false;

  /// Call once at startup (Android only).
  Future<void> init() async {
    if (_started || kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShare' && call.arguments is Map) {
        _receive(IncomingShare.fromMap(call.arguments as Map));
      }
    });
    try {
      final initial = await _channel.invokeMethod<Map>('ready');
      if (initial != null) _receive(IncomingShare.fromMap(initial));
    } catch (e) {
      debugPrint('ShareIntake: ready failed: $e');
    }
  }

  /// AuthGate: the user is signed in with a profile — show anything held.
  void onSignedIn() {
    _ready = true;
    final share = _pending;
    if (share != null) {
      _pending = null;
      _present(share);
    }
  }

  void _receive(IncomingShare share) {
    if (share.isEmpty) return;
    if (!_ready) {
      _pending = share;
      return;
    }
    _present(share);
  }

  void _present(IncomingShare share) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = CallNavigator.key.currentState;
      if (nav == null) {
        _pending = share;
        return;
      }
      nav.push(MaterialPageRoute(
        builder: (_) => ShareTargetScreen(share: share),
      ));
    });
  }
}
