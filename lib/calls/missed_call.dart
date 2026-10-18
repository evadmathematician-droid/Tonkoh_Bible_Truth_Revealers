import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../data/chat_summary.dart';
import '../data/display_names.dart';
import '../data/local_chat_store.dart';
import '../data/private_message.dart';
import '../screens/chat/chat_helpers.dart' show privateChatId;
import 'call_notifications.dart';

/// Logs an unanswered call as a WhatsApp-style "Missed call" entry in the
/// private chat, and (for the person who missed it) shows a notification.
///
/// Both sides record their own entry into their own local store + chat
/// summary — no cross-relay is needed for that. The message id is derived
/// from the call id, so if the caller ALSO relays it to a killed callee
/// ([relayToPeer]), the callee's relay listener replaces its local copy
/// rather than adding a duplicate.
class MissedCallLog {
  MissedCallLog._();

  static String _msgId(String callId) => 'missed_$callId';

  static String _label(String callType) =>
      callType.toLowerCase() == 'video'
          ? '📞 Missed video call'
          : '📞 Missed voice call';

  static PrivateMessage _message({
    required String callId,
    required String callType,
    required int ts,
    required String senderId,
    required String senderName,
  }) {
    final isVideo = callType.toLowerCase() == 'video';
    return PrivateMessage(
      id: _msgId(callId),
      type: 'call',
      // Rendered by the 'call' bubble; the direction is derived from
      // senderId == myUid at display time.
      text: isVideo ? 'missed_video' : 'missed_voice',
      timestamp: ts,
      senderId: senderId,
      senderName: senderName,
    );
  }

  /// Record the missed call on THIS device.
  ///
  /// [incoming] true  = I didn't answer the other person's call.
  /// [incoming] false = the other person didn't answer my call.
  static Future<void> recordLocal({
    required String callId,
    required String selfUid,
    required String otherUid,
    required String otherName,
    String otherPhoto = '',
    required String callType,
    required bool incoming,
    bool notify = false,
  }) async {
    try {
      final cid = privateChatId(selfUid, otherUid);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final label = _label(callType);

      final msg = _message(
        callId: callId,
        callType: callType,
        ts: ts,
        // Incoming missed → shown as the other person's message (left);
        // outgoing missed → my message (right).
        senderId: incoming ? otherUid : selfUid,
        senderName: incoming ? otherName : '',
      );
      await LocalChatStore.instance.insert(cid, msg);

      await _bumpSummary(
        db: FirebaseDatabase.instance,
        ownerUid: selfUid,
        cid: cid,
        otherUid: otherUid,
        otherName: otherName,
        otherPhoto: otherPhoto,
        label: label,
        ts: ts,
        incrementUnread: incoming,
      );

      if (notify) {
        await CallNotifications.showMissedCall(
          callerName: DisplayNames.instance.nameFor(otherUid),
          callType: callType,
          chatId: cid,
        );
      }
    } catch (e) {
      debugPrint('MissedCallLog.recordLocal failed: $e');
    }
  }

  /// Caller-only: also write the missed-call entry to the callee's relay
  /// node + chat summary, so a device that was killed during the ring still
  /// picks up the record (and unread badge) next time it syncs. No push here
  /// — a live callee shows its own local notification, and a killed callee
  /// already got the full-screen "incoming call" push.
  static Future<void> relayToPeer({
    required String callId,
    required String callerUid,
    required String callerName,
    required String calleeUid,
    required String callType,
  }) async {
    try {
      final db = FirebaseDatabase.instance;
      final cid = privateChatId(callerUid, calleeUid);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final label = _label(callType);

      final msg = _message(
        callId: callId,
        callType: callType,
        ts: ts,
        senderId: callerUid,
        senderName: callerName,
      );
      await db
          .ref('privateChats/$cid/messages')
          .child(_msgId(callId))
          .set(msg.toFirebaseMap());

      await _bumpSummary(
        db: db,
        ownerUid: calleeUid,
        cid: cid,
        otherUid: callerUid,
        otherName: callerName,
        otherPhoto: '',
        label: label,
        ts: ts,
        incrementUnread: true,
      );
    } catch (e) {
      debugPrint('MissedCallLog.relayToPeer failed: $e');
    }
  }

  static Future<void> _bumpSummary({
    required FirebaseDatabase db,
    required String ownerUid,
    required String cid,
    required String otherUid,
    required String otherName,
    required String otherPhoto,
    required String label,
    required int ts,
    required bool incrementUnread,
  }) async {
    final ref = db.ref('userChats/$ownerUid/$cid');
    final existing = await ref.get();
    if (existing.exists) {
      await ref.update({'lastMessage': label, 'lastTimestamp': ts});
    } else {
      await ref.set(ChatSummary(
        chatId: cid,
        otherUid: otherUid,
        otherName: otherName.isEmpty ? 'Chat' : otherName,
        otherPhotoUrl: otherPhoto,
        lastMessage: label,
        lastTimestamp: ts,
        unread: 0,
        lastReadTimestamp: 0,
      ).toFirebaseMap());
    }
    if (incrementUnread) {
      await ref.child('unread').runTransaction((current) {
        final n = (current as num?)?.toInt() ?? 0;
        return Transaction.success(n + 1);
      });
    }
  }
}
