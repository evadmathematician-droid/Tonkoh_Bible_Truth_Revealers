import 'package:flutter/material.dart';

import '../data/phone_aliases.dart';
import '../data/user_profile.dart';
import '../navigation/call_navigator.dart';
import '../screens/chat/chat_helpers.dart' show privateChatId;
import 'call_initiator.dart';

/// Starts a one-to-one app call (voice or video) through the private-chat
/// calling system.
///
/// This is the single entry point shared by the in-chat call buttons on
/// [PrivateChatScreen] and the "Voice Call" / "Video Call" actions on the
/// contacts action sheet, so a call placed from the contacts screen is
/// identical to one placed from inside the chat — same `calls/{id}` record,
/// same signalling, same outgoing-call UI.
///
/// [callType] is `'audio'` or `'video'`. [calleeUid] must be the other
/// user's account id (their E.164 phone number — the same value used as the
/// private-chat route parameter). A contact with no app account cannot be
/// called and should be handled by the caller before this runs.
/// Set for the brief window between a call button being tapped and the
/// outgoing-call screen being pushed. A second tap (double-tap, a bounced
/// touch, two call buttons) that lands in that window is ignored, so one tap
/// can never start two calls. [CallInitiator] has its own server-side
/// idempotency guard as a backstop; this one just keeps the UI honest.
bool _dialInFlight = false;

Future<void> startPrivateAppCall({
  required BuildContext context,
  required UserProfile caller,
  required String calleeUid,
  required String calleeName,
  required String callType,
}) async {
  if (_dialInFlight) {
    debugPrint('startPrivateAppCall: ignored — a dial is already in flight');
    return;
  }
  if (caller.uid.isEmpty || calleeUid.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Call not ready yet — try again in a moment.')),
      );
    }
    return;
  }

  // Old data can hand us a malformed or moved account id.
  calleeUid = resolveUserId(calleeUid);

  _dialInFlight = true;
  try {
    final chatId = privateChatId(caller.uid, calleeUid);
    final initiator = CallInitiator();
    await initiator.initiateCall(
      callerUid: caller.uid,
      callerName: caller.name,
      callerPhoto: caller.photoUrl,
      calleeUid: calleeUid,
      chatId: chatId,
      callType: callType,
      onCallIdReady: (callId) {
        CallNavigator.toOutgoingCall(
          callId: callId,
          callerUid: caller.uid,
          callerName: caller.name,
          calleeUid: calleeUid,
          calleeName: calleeName,
          callType: callType,
        );
      },
    );
  } finally {
    // Release a beat later: the outgoing-call screen has been pushed by now,
    // so any queued duplicate tap is discarded rather than racing this reset.
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      _dialInFlight = false;
    });
  }
}
