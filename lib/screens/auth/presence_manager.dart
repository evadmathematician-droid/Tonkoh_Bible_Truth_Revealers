import 'package:firebase_database/firebase_database.dart';

/// Equivalent of PresenceManager.kt. Tracks whether the signed-in user is
/// online using Firebase's standard .info/connected + onDisconnect()
/// pattern, so presence stays correct even if the app is killed, crashes,
/// or loses network — Firebase's own servers flip the value, not client
/// code that might never run.
///
/// Without this, users signed in on iOS/web/Windows never mark themselves
/// online at all — other users would only ever see their Android chat
/// partners' presence, never a web/iOS/Windows partner's.
///
/// Call PresenceManager.start(uid) once, right after sign-in.
class PresenceManager {
  PresenceManager._();

  static bool _started = false;

  static void start(String uid) {
    if (_started) return;
    _started = true;

    final myPresenceRef = FirebaseDatabase.instance.ref('presence/$uid');
    final connectedRef = FirebaseDatabase.instance.ref('.info/connected');

    connectedRef.onValue.listen((event) {
      final connected = event.snapshot.value == true;
      if (!connected) return;

      // As soon as we (re)connect, tell the server what to write if THIS
      // connection drops unexpectedly — this fires server-side even on a
      // crash, force-close, or closed browser tab.
      myPresenceRef.onDisconnect().set({
        'online': false,
        'lastSeen': ServerValue.timestamp,
      });
      myPresenceRef.set({
        'online': true,
        'lastSeen': ServerValue.timestamp,
      });
    });
  }
}
