import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'call_models.dart';
import 'platform_call_support.dart';

class CallSignalingRepository {
  final FirebaseDatabase _db = FirebaseDatabase.instance;

  DatabaseReference _callRef(String callId) => _db.ref('calls').child(callId);

  Future<String> createCall(CallSession session) async {
    final ref = _db.ref('calls').push();
    final callId = ref.key!;
    final data = session
        .copyWith(callId: callId, createdAt: DateTime.now().millisecondsSinceEpoch)
        .toMap();
    await ref.set(data);
    return callId;
  }

  Future<void> setState(String callId, CallState state) async {
    await _callRef(callId).child('state').set(state.name.toUpperCase());
  }

  StreamSubscription<DatabaseEvent> observeState(
      String callId,
      void Function(CallState state) onChange,
      ) {
    return _callRef(callId).child('state').onValue.listen((event) {
      final raw = event.snapshot.value as String?;
      onChange(CallSession.parseCallState(raw));
    });
  }

  void stopObservingState(String callId, StreamSubscription<DatabaseEvent> sub) {
    sub.cancel();
  }

  Future<void> sendOffer(String callId, String sdp) async {
    await _callRef(callId).child('offer').set(SdpPayload(type: 'offer', sdp: sdp).toMap());
  }

  Future<void> sendAnswer(String callId, String sdp) async {
    await _callRef(callId).child('answer').set(SdpPayload(type: 'answer', sdp: sdp).toMap());
  }

  StreamSubscription<DatabaseEvent> observeOffer(
      String callId,
      void Function(String sdp) onOffer,
      ) {
    return _callRef(callId).child('offer').onValue.listen((event) {
      if (!event.snapshot.exists) return;
      final val = event.snapshot.value;
      if (val is Map) {
        final type = val['type'] as String?;
        if (type == 'offer') onOffer((val['sdp'] ?? '') as String);
      }
    });
  }

  StreamSubscription<DatabaseEvent> observeAnswer(
      String callId,
      void Function(String sdp) onAnswer,
      ) {
    return _callRef(callId).child('answer').onValue.listen((event) {
      if (!event.snapshot.exists) return;
      final val = event.snapshot.value;
      if (val is Map) {
        final type = val['type'] as String?;
        if (type == 'answer') onAnswer((val['sdp'] ?? '') as String);
      }
    });
  }

  Future<void> sendIceCandidate(String callId, bool isCaller, IceCandidateModel candidate) async {
    final childName = isCaller ? 'callerCandidates' : 'calleeCandidates';
    await _callRef(callId).child(childName).push().set(candidate.toMap());
  }

  StreamSubscription<DatabaseEvent> observeRemoteIceCandidates(
      String callId,
      bool isCaller,
      void Function(IceCandidateModel candidate) onCandidate,
      ) {
    final childName = isCaller ? 'calleeCandidates' : 'callerCandidates';
    return _callRef(callId).child(childName).onChildAdded.listen((event) {
      final val = event.snapshot.value;
      if (val is Map) onCandidate(IceCandidateModel.fromMap(val));
    });
  }

  void removeAllListeners(String callId) {
    // Dart streams are subscription-based; callers cancel their own subs.
    // This is a no-op placeholder to match the Kotlin API surface.
  }

  Future<void> deleteCall(String callId) async {
    await _callRef(callId).remove();
  }

  /// Removes the whole `calls/{callId}` node a few seconds after a terminal
  /// state (DECLINED / MISSED / CANCELLED / ENDED) has been written.
  ///
  /// Why the delay: the peer reacts to the terminal state through its own
  /// `state` listener. Deleting the node immediately would surface as a
  /// `null` state that matches none of the peer's "call over" cases, so the
  /// peer's screen could hang. A short grace period lets that write land
  /// first.
  ///
  /// Why delete at all: the incoming-call listener is a `calls`
  /// `onChildAdded` query, which replays *every* matching node when it
  /// attaches. Call docs that are only ever state-flipped (never removed)
  /// pile up and get re-delivered as phantom incoming calls on the next
  /// launch or reconnect — the duplicate-ring bug. This is the cleanup the
  /// decline / timeout / cancel / hang-up paths were missing.
  void scheduleCleanup(
    String callId, {
    Duration delay = const Duration(seconds: 6),
  }) {
    Future.delayed(delay, () {
      deleteCall(callId).then(
        (_) => debugPrint('CallSignalingRepository: cleaned up call doc $callId'),
        onError: (e) => debugPrint(
            'CallSignalingRepository: cleanup delete failed for $callId: $e'),
      );
    });
  }

  /// Terminal hang-up: writes [state] to `calls/{callId}/state`, cancels this
  /// client's `onDisconnect` fallback, then schedules the node's removal.
  ///
  /// Only the side that *initiates* the end (user taps end / decline /
  /// cancel, or a local failure teardown) calls this. The peer reacts to the
  /// state change by tearing down locally — it must NOT call this back, or a
  /// late write could resurrect the node the initiator just deleted. This is
  /// how a hang-up on one device reaches the other: an explicit `ENDED`
  /// value lands and settles *before* the doc disappears, so the peer's
  /// `state` listener always sees the transition (not just a missed delete).
  Future<void> endCall(String callId, {String state = 'ENDED'}) async {
    try {
      await _callRef(callId).child('state').set(state);
    } catch (e) {
      debugPrint(
          'CallSignalingRepository: failed to write $state for $callId: $e');
    }
    await disarmDisconnectEnd(callId);
    scheduleCleanup(callId);
  }

  /// Arms a Firebase `onDisconnect` write so that if THIS client's socket
  /// drops without a clean hang-up (process killed, crash, connectivity
  /// lost), the RTDB server still flips `calls/{callId}/state` to [state].
  /// Without this the peer sits ringing / "Connecting…" forever when no end
  /// signal is ever sent. Pair every arm with a [disarmDisconnectEnd] on the
  /// normal teardown path.
  Future<void> armDisconnectEnd(String callId, {String state = 'ENDED'}) async {
    try {
      await _callRef(callId).child('state').onDisconnect().set(state);
    } catch (e) {
      debugPrint(
          'CallSignalingRepository: armDisconnectEnd failed for $callId: $e');
    }
  }

  Future<void> disarmDisconnectEnd(String callId) async {
    try {
      await _callRef(callId).child('state').onDisconnect().cancel();
    } catch (e) {
      debugPrint(
          'CallSignalingRepository: disarmDisconnectEnd failed for $callId: $e');
    }
  }

  // -----------------------------------------------------------------
  // INCOMING CALL LISTENER
  // -----------------------------------------------------------------

  StreamSubscription<DatabaseEvent>? _incomingListener;

  /// [onIncomingCall] also receives [callerPhoto] and [chatId].
  ///
  /// FIX (double-ring bug): this is now a hard no-op on Android. Android's
  /// native Kotlin stack (OneSignal push -> TelecomCallManager ->
  /// CallConnectionService -> CallService) is the sole source of truth for
  /// incoming calls there. Previously this RTDB query ran on every platform
  /// including Android, so a single "calls/{id}" write triggered BOTH the
  /// native ring AND this listener's ring on the same device — the
  /// duplicate-ring bug. Guarding here (not just inside IncomingCallManager)
  /// means the query itself never even attaches on Android, regardless of
  /// where this method is called from.
  void startListeningForIncomingCalls(
      String myUid,
      void Function(
          String callId,
          String callerUid,
          String callerName,
          String callerPhoto,
          String chatId,
          String type,
          ) onIncomingCall,
      ) {
    if (callsHandledNatively) {
      debugPrint(
          'CallSignalingRepository: not attaching incoming-call listener — Android handles this natively');
      return;
    }

    final query = _db.ref('calls').orderByChild('calleeId').equalTo(myUid);
    _incomingListener = query.onChildAdded.listen((event) {
      final snapshot = event.snapshot;
      final callId = snapshot.child('callId').value as String? ?? snapshot.key;
      if (callId == null || callId.isEmpty) return;

      final calleeUid = snapshot.child('calleeId').value as String?;
      if (calleeUid != myUid) return;

      final stateRaw = snapshot.child('state').value as String? ??
          snapshot.child('status').value as String?;
      if (stateRaw?.toUpperCase() != 'RINGING') return;

      final createdAt = (snapshot.child('createdAt').value as int?) ??
          (snapshot.child('timestamp').value as int?) ??
          0;
      final ageMs = DateTime.now().millisecondsSinceEpoch - createdAt;
      if (ageMs > 30000) {
        debugPrint('FirebaseSignaling: Ignoring stale call $callId (age=${ageMs ~/ 1000}s)');
        if (ageMs > 300000) snapshot.ref.remove();
        return;
      }

      final type = snapshot.child('type').value as String? ??
          snapshot.child('callType').value as String? ??
          'audio';

      final callerUid = snapshot.child('callerId').value as String? ?? '';
      final callerName = snapshot.child('callerName').value as String? ?? 'Unknown';
      final callerPhoto = snapshot.child('callerPhoto').value as String? ??
          snapshot.child('callerPhotoUrl').value as String? ??
          '';
      final chatId = snapshot.child('chatId').value as String? ?? '';

      debugPrint('FirebaseSignaling: 📞 Incoming call: $callId type=$type from=$callerName');
      onIncomingCall(callId, callerUid, callerName, callerPhoto, chatId, type);
    });
  }

  void stopListeningForIncomingCalls() {
    _incomingListener?.cancel();
    _incomingListener = null;
  }
}