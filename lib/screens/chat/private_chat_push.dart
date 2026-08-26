import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;

const String _pushRelayUrl =
    'https://small-dream-b231.tonkohbibletruthrevealers.workers.dev/send-push';
const String _pushRelaySecret = 'test-relay-secret-123'; // must match RELAY_SECRET set in the Worker's env

/// Sends a chat push via the Cloudflare Worker relay instead of calling
/// OneSignal's REST API directly — the real OneSignal REST key lives only
/// in the Worker's env (ONESIGNAL_REST_API_KEY), never in client code. Was
/// previously a direct api.onesignal.com call with a hardcoded key here;
/// that key got flagged and blocked by GitHub push protection.
Future<void> sendPrivateChatPushNotification({
  required String otherUid,
  required String? chatId,
  required String senderName,
  required String messageBody,
  required String senderUid,
}) async {
  if (chatId == null) return;

  try {
    final snapshot =
    await FirebaseDatabase.instance.ref('users/$otherUid/oneSignalId').get();
    final playerId = snapshot.value as String?;
    if (playerId == null || playerId.isEmpty) {
      return; // Receiver has no OneSignal id yet.
    }

    await http.post(
      Uri.parse(_pushRelayUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'secret': _pushRelaySecret,
        'subscriptionIds': [playerId],
        'heading': senderName,
        'content': messageBody,
        'data': {'senderUid': senderUid, 'chatId': chatId},
      }),
    );
  } catch (_) {
    // Best-effort — a failed push shouldn't block sending the message.
  }
}
