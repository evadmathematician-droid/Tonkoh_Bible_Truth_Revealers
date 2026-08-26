import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'call_models.dart';

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

  // -----------------------------------------------------------------
  // INCOMING CALL LISTENER
  // -----------------------------------------------------------------

  StreamSubscription<DatabaseEvent>? _incomingListener;

  /// [onIncomingCall] now also receives [callerPhoto] and [chatId], which
  /// were already present on the RTDB snapshot but previously not read.
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
    _incomingListener?.cancel();

    final query = _db
        .ref('calls')
        .orderByChild('calleeId')
        .equalTo(myUid);

    _incomingListener = query.onChildAdded.listen(
          (event) {
        final snapshot = event.snapshot;

        final callId =
            snapshot.child('callId').value?.toString() ??
                snapshot.key;

        if (callId == null || callId.isEmpty) {
          debugPrint(
            'FirebaseSignaling: Invalid call ID',
          );
          return;
        }

        final calleeUid =
        snapshot.child('calleeId').value?.toString();

        if (calleeUid != myUid) {
          return;
        }

        final stateRaw =
            snapshot.child('state').value?.toString() ??
                snapshot.child('status').value?.toString();

        final state =
        stateRaw?.toUpperCase();

        if (state != 'RINGING') {
          debugPrint(
            'FirebaseSignaling: Ignoring $callId '
                'because state is $state',
          );
          return;
        }

        final createdValue =
            snapshot.child('createdAt').value ??
                snapshot.child('timestamp').value;

        final createdAt =
        createdValue is num
            ? createdValue.toInt()
            : int.tryParse(
          createdValue?.toString() ?? '',
        ) ??
            0;

        if (createdAt <= 0) {
          debugPrint(
            'FirebaseSignaling: Call $callId '
                'has invalid timestamp',
          );
          return;
        }

        final ageMs =
            DateTime.now()
                .millisecondsSinceEpoch -
                createdAt;

        // Ignore calls older than 60 seconds.
        if (ageMs > 60000) {
          debugPrint(
            'FirebaseSignaling: Ignoring stale call '
                '$callId '
                'age=${ageMs ~/ 1000}s',
          );

          // Clean up very old abandoned calls.
          if (ageMs > 300000) {
            snapshot.ref.remove();
          }

          return;
        }

        final type =
            snapshot.child('type').value?.toString() ??
                snapshot.child('callType').value?.toString() ??
                'audio';

        final callerUid =
            snapshot.child('callerId').value?.toString() ??
                '';

        final callerName =
            snapshot.child('callerName').value?.toString() ??
                'Unknown';

        final callerPhoto =
            snapshot.child('callerPhoto').value?.toString() ??
                snapshot
                    .child('callerPhotoUrl')
                    .value
                    ?.toString() ??
                '';

        final chatId =
            snapshot.child('chatId').value?.toString() ??
                '';

        debugPrint(
          'FirebaseSignaling: 📞 INCOMING CALL\n'
              'callId: $callId\n'
              'from: $callerName\n'
              'type: $type\n'
              'age: ${ageMs ~/ 1000}s',
        );

        onIncomingCall(
          callId,
          callerUid,
          callerName,
          callerPhoto,
          chatId,
          type,
        );
      },
      onError: (error) {
        debugPrint(
          'FirebaseSignaling incoming listener error: '
              '$error',
        );
      },
    );
  }

  void stopListeningForIncomingCalls() {
    _incomingListener?.cancel();
    _incomingListener = null;
  }
}