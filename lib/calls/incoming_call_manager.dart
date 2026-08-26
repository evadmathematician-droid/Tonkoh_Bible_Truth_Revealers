import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../navigation/call_navigator.dart';
import 'call_notifications.dart';

class IncomingCallManager {
  static final IncomingCallManager instance =
  IncomingCallManager._();

  IncomingCallManager._();

  String? _currentCallId;
  String? _currentCallType;
  String? _currentCallerName;

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
    // Do not process the same call twice.
    if (_currentCallId == callId) {
      debugPrint(
        'IncomingCallManager: Call $callId is already active',
      );
      return;
    }

    // Clear an old call before accepting a new one.
    if (_currentCallId != null &&
        _currentCallId != callId) {
      await clearIncomingCall();
    }

    _currentCallId = callId;
    _currentCallType = callType;
    _currentCallerName = callerName;

    debugPrint(
      'IncomingCallManager: Incoming $callType call '
          'from $callerName. Call ID: $callId',
    );

    try {
      await CallNotifications.showIncomingCall(
        callId: callId,
        callType: callType,
        callerName: callerName,
      );
    } catch (e) {
      // A notification-display failure (e.g. permission not yet granted,
      // OEM quirk) must not leave _currentCallId set with no timeout timer
      // and no state watcher running — that would silently block this call
      // AND make the dedup guard above swallow any retry with the same
      // callId. Fall through to still start the timer/watcher so the call
      // can time out or be cancelled normally instead of hanging forever.
      debugPrint('IncomingCallManager: showIncomingCall failed: $e');
    }

    // flutter_local_notifications has no web implementation at all — its
    // initialize()/show() are silent kIsWeb no-ops (confirmed in the
    // package source), so showIncomingCall() above never displays anything
    // and CallNotifications.actionStream never fires on web. Without this,
    // a web callee would never see or hear an incoming call. Navigate
    // straight to the call screen instead of relying on a notification tap.
    if (kIsWeb) {
      CallNavigator.toIncomingCall(
        callId: callId,
        callerId: callerId,
        callerName: callerName,
        callerPhoto: callerPhoto,
        chatId: chatId,
        callType: callType,
      );
    }

    _startTimeoutTimer(callId);

    _watchForRemoteStateChange(callId);
  }

  void _startTimeoutTimer(String callId) {
    _timeoutTimer?.cancel();

    _timeoutTimer = Timer(
      const Duration(seconds: 45),
          () async {
        if (_currentCallId == callId) {
          debugPrint(
            'IncomingCallManager: Call timed out',
          );

          await FirebaseDatabase.instance
              .ref('calls')
              .child(callId)
              .child('state')
              .set('MISSED');

          await clearIncomingCall();
        }
      },
    );
  }

  void _watchForRemoteStateChange(String callId) {
    _stateSub?.cancel();

    _stateSub = FirebaseDatabase.instance
        .ref('calls')
        .child(callId)
        .child('state')
        .onValue
        .listen((event) async {
      final raw = event.snapshot.value;

      final state = raw
          ?.toString()
          .toUpperCase();

      debugPrint(
        'IncomingCallManager: $callId state = $state',
      );

      // ACCEPTED is included here because IncomingCallScreen.accept() (the
      // ONLY path on web, now that handleIncomingCall navigates straight to
      // it above) writes this state directly to RTDB without ever calling
      // acceptCall() below. Without this, _timeoutTimer above would still
      // be running and would overwrite the call back to MISSED 45s after
      // every answered web call.
      if (state == 'ACCEPTED' ||
          state == 'ENDED' ||
          state == 'CANCELLED' ||
          state == 'DECLINED' ||
          state == 'MISSED') {
        await clearIncomingCall();
      }
    });
  }

  Future<void> acceptCall() async {
    final callId = _currentCallId;

    if (callId == null) return;

    await FirebaseDatabase.instance
        .ref('calls')
        .child(callId)
        .child('state')
        .set('ACCEPTED');

    await clearIncomingCall();
  }

  Future<void> declineCall({
    String reason = 'DECLINED',
  }) async {
    final callId = _currentCallId;

    if (callId == null) return;

    await FirebaseDatabase.instance
        .ref('calls')
        .child(callId)
        .child('state')
        .set(reason);

    await clearIncomingCall();
  }

  Future<void> clearIncomingCall() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    await _stateSub?.cancel();
    _stateSub = null;

    _currentCallId = null;
    _currentCallType = null;
    _currentCallerName = null;

    await CallNotifications.cancelIncoming();
  }

  Future<void> endCall() async {
    await clearIncomingCall();
  }
}