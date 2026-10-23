import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/widgets.dart';

/// Equivalent of PresenceManager.kt. The user is "Online" only while TBTR
/// is on screen, like WhatsApp: leaving or closing the app writes
/// `{online: false, lastSeen}` straight away.
///
/// `presence/{uid} = {online: bool, lastSeen: ms}`.
///
/// Uses Firebase's .info/connected + onDisconnect() pattern, so a lost
/// connection (data off, app killed, phone off) also flips the user to
/// "Last seen" — Firebase's own servers write it, not code that might never
/// run.
///
/// Started from AuthGate once the account is known; stopped on sign-out.
class PresenceManager with WidgetsBindingObserver {
  PresenceManager._();
  static final PresenceManager _instance = PresenceManager._();

  static String? _uid;
  static StreamSubscription<DatabaseEvent>? _connectedSub;
  static bool _observing = false;

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
      // A reconnect while the app is in the background must not flip the
      // user back to Online.
      if (_isForeground) myPresenceRef.set(_value(true));
    });
  }

  /// Signed out. [markOffline] false when the account now belongs to
  /// another device (its status is that device's to write).
  static Future<void> stop({bool markOffline = true}) async {
    final uid = _uid;
    _uid = null;
    await _connectedSub?.cancel();
    _connectedSub = null;
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final uid = _uid;
    if (uid == null) return;
    final ref = FirebaseDatabase.instance.ref('presence/$uid');
    switch (state) {
      case AppLifecycleState.resumed:
        ref.set(_value(true));
      // Home / app switcher / screen off (paused), or the app being closed
      // (detached): Last seen now.
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        ref.set(_value(false));
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }
}
