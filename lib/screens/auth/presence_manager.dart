import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Equivalent of PresenceManager.kt. Tracks whether the signed-in user is
/// online using Firebase's standard .info/connected + onDisconnect()
/// pattern, so presence stays correct even if the app is killed, crashes,
/// or loses network — Firebase's own servers flip the value, not client
/// code that might never run.
///
/// `presence/{uid} = {online: bool, lastSeen: ms}`.
///
/// On Android, "Stay online in background" (Settings, on by default) also
/// runs the native `PresenceService`: a small foreground service that keeps
/// the connection — and so the "Online" status — alive while another app is
/// open. With it off, the user shows "Last seen" as soon as they leave the
/// app.
///
/// Started from AuthGate once the account is known; stopped on sign-out.
class PresenceManager with WidgetsBindingObserver {
  PresenceManager._();
  static final PresenceManager _instance = PresenceManager._();

  static const MethodChannel _native = MethodChannel('com.tbtrapp/presence');
  static const String _prefKey = 'presence.stay_online_bg';

  static String? _uid;
  static StreamSubscription<DatabaseEvent>? _connectedSub;
  static bool _observing = false;
  static bool _stayOnline = true;

  static bool get _hasNativeService =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// "Stay online in background" — on unless the user turned it off.
  static Future<bool> stayOnlineInBackground() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKey) ?? true;
  }

  static Future<void> setStayOnlineInBackground(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
    _stayOnline = value;
    await _configureNative();
  }

  static void start(String uid) {
    if (_uid == uid) return;
    _connectedSub?.cancel();
    _uid = uid;

    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(_instance);
    }

    final myPresenceRef = FirebaseDatabase.instance.ref('presence/$uid');
    _connectedSub = FirebaseDatabase.instance
        .ref('.info/connected')
        .onValue
        .listen((event) {
      final connected = event.snapshot.value == true;
      if (!connected) return;

      // As soon as we (re)connect, tell the server what to write if THIS
      // connection drops unexpectedly — this fires server-side even on a
      // crash, force-close, or closed browser tab.
      myPresenceRef.onDisconnect().set(_value(false));
      // Backgrounded with the setting off: reconnecting must not flip the
      // user back to Online.
      if (_stayOnline || _isForeground) myPresenceRef.set(_value(true));
    });

    unawaited(() async {
      _stayOnline = await stayOnlineInBackground();
      await _configureNative();
    }());
  }

  /// Signed out. [markOffline] false when the account now belongs to
  /// another device (its status is that device's to write).
  static Future<void> stop({bool markOffline = true}) async {
    final uid = _uid;
    _uid = null;
    await _connectedSub?.cancel();
    _connectedSub = null;
    await _configureNative();
    if (uid == null || !markOffline) return;
    try {
      final ref = FirebaseDatabase.instance.ref('presence/$uid');
      await ref.onDisconnect().cancel();
      await ref.set(_value(false));
    } catch (e) {
      debugPrint('PresenceManager: mark offline failed: $e');
    }
  }

  static Map<String, Object> _value(bool online) =>
      {'online': online, 'lastSeen': ServerValue.timestamp};

  static bool get _isForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  static Future<void> _configureNative() async {
    if (!_hasNativeService) return;
    try {
      await _native.invokeMethod('configure', {
        'uid': _uid,
        'enabled': _stayOnline,
      });
    } catch (e) {
      debugPrint('PresenceManager: native presence unavailable: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final uid = _uid;
    if (uid == null) return;
    final ref = FirebaseDatabase.instance.ref('presence/$uid');
    if (state == AppLifecycleState.resumed) {
      ref.set(_value(true));
      // Restart the background service if Android stopped it while the
      // app was away (only possible from the foreground).
      unawaited(_configureNative());
    } else if (state == AppLifecycleState.paused && !_stayOnline) {
      ref.set(_value(false));
    }
  }
}
