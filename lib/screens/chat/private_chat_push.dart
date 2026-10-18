import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;

import '../../config/worker_api.dart';

// Relayed through the Cloudflare Worker (same one call_initiator.dart uses for
// /send-call-push) instead of embedding the
// OneSignal REST API key in client code — that key must never ship in a
// build a user can inspect (this matters even more on Flutter web, where
// it'd sit in plain text in the compiled JS). The Worker authorises the
// call by the sender's Firebase ID token (WorkerApi.headers).

/// Mirrors Kotlin's sendPushNotification(): looks up the recipient's
/// OneSignal player id from `users/{otherUid}/oneSignalId`, then relays the
/// push through the Worker instead of calling OneSignal directly.
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
      Uri.parse(WorkerApi.sendPushUrl),
      headers: await WorkerApi.headers(),
      body: jsonEncode({
        'secret': WorkerApi.legacySecret,
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
