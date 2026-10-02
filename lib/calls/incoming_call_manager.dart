import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:vibration/vibration.dart';
import '../navigation/call_navigator.dart';
import 'call_notifications.dart';
import 'call_signaling_repository.dart';
import 'incoming_ringtone.dart';
import 'missed_call.dart';
import 'platform_call_support.dart';

class IncomingCallManager {
  static final IncomingCallManager instance = IncomingCallManager._();
  IncomingCallManager._();

  final CallSignalingRepository _signaling = CallSignalingRepository();

  String? _currentCallId;
  String? _currentCallType;
  String? _currentCallerName;
  String? _currentCallerId;
  String? _currentCallerPhoto;
  String? _currentChatId;
  bool _wasAccepted = false;
  Timer? _timeoutTimer;
  StreamSubscription<DatabaseEvent>? _stateSub;

  bool get hasActiveCall => _currentCallId != null;
  String? get currentCallId => _currentCallId;
  String? get currentCallType => _currentCallType;

  Future<void> handleIncomingCall({
    required String callId,
    required String callerId,
    required String callerName,
    required String callerPhoto,
    required String chatId,
    required String callType,
  }) async {
    // FIX (double-ring bug): Android's native Kotlin stack
    // (TelecomCallManager + CallService + CallConnectionService) already
    // owns ringing there, including killed-process state, which Flutter
    // cannot reliably replicate. If this ever gets called on Android
    // (e.g. because the RTDB listener that feeds it wasn't itself gated),
    // bail out immediately instead of ringing a second time.
    if (callsHandledNatively) {
      debugPrint(
          'IncomingCallManager: ignoring $callId — Android calls handled natively');
      return;
    }

    // De-dupe: the RTDB `onChildAdded` listener replays every `calls/*` node
    // whose `calleeId` matches us, so stale/abandoned call docs from earlier
    // test runs (and a rapid video-then-audio retry from the same caller)
    // surface as several "incoming call" events in a row. Only ring for the
    // first one; ignore anything that arrives while a call is already active.
    if (_currentCallId != null) {
      debugPrint(
          'IncomingCallManager: ignoring $callId — already handling $_currentCallId');
      return;
    }

    _clearState();
    _currentCallId = callId;
    _currentCallType = callType;
    _currentCallerName = callerName;
    _currentCallerId = callerId;
    _currentCallerPhoto = callerPhoto;
    _currentChatId = chatId;
    _wasAccepted = false;

    // flutter_local_notifications has no web implementation, so on web the
    // notification is not just invisible — the plugin call would throw. The
    // in-app ringing screen below is the actual incoming-call UI there.
    if (!kIsWeb) {
      await CallNotifications.showIncomingCall(
        callId: callId,
        callType: callType,
        callerName: callerName,
      );
    }

    // Push the in-app ringing screen. On web/desktop this is the only
    // incoming call UI; on iOS it complements the notification. Android
    // never reaches here — see the guard above.
    CallNavigator.toIncomingCall(
      callId: callId,
      callerId: callerId,
      callerName: callerName,
      callerPhoto: callerPhoto,
      chatId: chatId,
      callType: callType,
    );

    _startTimeoutTimer(callId);
    _watchForRemoteStateChange(callId);
    _startRingVibration();
    // Looping ringtone audio (native, ring stream). Vibration above and this
    // are the two halves of "ringing"; both are cancelled together in
    // [_clearState] on answer / decline / hang-up / timeout.
    IncomingRingtone.instance.start();

    // If we die / drop while ringing, mark the call MISSED so the caller
    // stops ringing. Disarmed on accept / decline / remote-end.
    _signaling.armDisconnectEnd(callId, state: 'MISSED');
  }

  /// Continuous call-cadence vibration for the duration of the ring. The
  /// notification's ringtone loops via FLAG_INSISTENT; a notification
  /// vibration pattern only fires once, so the looping buzz is driven here
  /// and cancelled from [_clearState] on answer / decline / hang-up /
  /// timeout. No-op on web / devices without a vibrator.
  Future<void> _startRingVibration() async {
    if (kIsWeb) return;
    try {
      if (await Vibration.hasVibrator() != true) return;
      Vibration.vibrate(
        pattern: const [0, 1000, 800, 1000, 800],
        repeat: 0, // loop the whole pattern until cancel()
      );
    } catch (e) {
      debugPrint('IncomingCallManager: ring vibration failed: $e');
    }
  }

  void _stopRingVibration() {
    if (kIsWeb) return;
    try {
      Vibration.cancel();
    } catch (_) {}
  }

  void _startTimeoutTimer(String callId) {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      if (_currentCallId == callId) {
        declineCall(reason: 'MISSED');
      }
    });
  }

  void _watchForRemoteStateChange(String callId) {
    _stateSub = FirebaseDatabase.instance
        .ref('calls')
        .child(callId)
        .child('state')
        .onValue
        .listen((event) {
      final state = event.snapshot.value as String?;
      // Caller hung up / cancelled while we were still ringing (or the doc
      // was removed). Dismiss the notification + ringing screen.
      if (state == null ||
          state == 'ENDED' ||
          state == 'CANCELLED' ||
          state == 'DECLINED' ||
          state == 'MISSED') {
        // Caller-initiated end while we were still ringing = a missed call
        // for us. (Our own decline / timeout already cleared _stateSub
        // before its write, so DECLINED/MISSED never actually reach here.)
        if (state == null || state == 'ENDED' || state == 'CANCELLED') {
          _logMissedIfUnanswered();
        }
        final id = _currentCallId;
        _clearState();
        CallNotifications.cancelIncoming();
        if (id != null) _signaling.disarmDisconnectEnd(id);
      }
    });
  }

  /// Records a "Missed call" chat entry + notification when this ring ended
  /// without being answered. Reads the call fields into locals first, so
  /// it's safe to call immediately before [_clearState].
  void _logMissedIfUnanswered() {
    if (_wasAccepted) return;
    final callId = _currentCallId;
    final callerId = _currentCallerId;
    final chatId = _currentChatId;
    if (callId == null ||
        callerId == null ||
        callerId.isEmpty ||
        chatId == null ||
        chatId.isEmpty) {
      return;
    }
    final selfUid =
        chatId.split('_').firstWhere((p) => p != callerId, orElse: () => '');
    if (selfUid.isEmpty) return;
    unawaited(MissedCallLog.recordLocal(
      callId: callId,
      selfUid: selfUid,
      otherUid: callerId,
      otherName: _currentCallerName ?? 'Unknown',
      otherPhoto: _currentCallerPhoto ?? '',
      callType: _currentCallType ?? 'audio',
      incoming: true,
      notify: true,
    ));
  }

  void acceptCall() {
    final id = _currentCallId;
    if (id == null) return;

    _wasAccepted = true;
    _signaling.disarmDisconnectEnd(id); // OngoingCallManager re-arms with ENDED
    FirebaseDatabase.instance.ref('calls').child(id).child('state').set('ACCEPTED');
    CallNotifications.cancelIncoming();
    _clearState();
    // No scheduleCleanup here: the accepted call keeps living in
    // `calls/{id}` — its offer/answer/ICE children carry the whole WebRTC
    // negotiation. That node is removed by OngoingCallManager.endCall()
    // when either side hangs up.
  }

  void declineCall({String reason = 'DECLINED'}) {
    final id = _currentCallId;
    if (id == null) return;

    // 45s no-answer auto-decline = a missed call. An explicit user decline
    // is not "missed".
    if (reason == 'MISSED') _logMissedIfUnanswered();

    CallNotifications.cancelIncoming();
    _clearState();
    // Writes the terminal state, cancels our onDisconnect fallback, then
    // schedules doc removal. Covers both an explicit decline and the 45 s
    // no-answer timeout (reason == 'MISSED').
    _signaling.endCall(id, state: reason);
  }

  void endCall() {
    final id = _currentCallId;
    CallNotifications.cancelIncoming();
    _clearState();
    if (id != null) _signaling.endCall(id);
  }

  void _clearState() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _stateSub?.cancel();
    _stateSub = null;
    _stopRingVibration();
    IncomingRingtone.instance.stop();
    _currentCallId = null;
    _currentCallType = null;
    _currentCallerName = null;
    _currentCallerId = null;
    _currentCallerPhoto = null;
    _currentChatId = null;
    _wasAccepted = false;
  }
}