import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../config/worker_api.dart';

// Sent by the Cloudflare Worker (cloudflare/worker_full.js /push/message),
// never with the OneSignal REST API key in client code. The Worker checks
// the sender's Firebase ID token (WorkerApi.headers) and that they are in
// [chatId], then pushes to the other person by OneSignal external ID.

/// Notifies the other person in [chatId] about a message just written.
/// [messageId] lets the Worker read the message itself; [messageBody] is
/// the preview it falls back to once the receiver's phone has taken the
/// message off the relay.
Future<void> sendPrivateChatPushNotification({
  required String otherUid,
  required String? chatId,
  required String senderName,
  required String messageBody,
  required String senderUid,
  String? messageId,
}) async {
  if (chatId == null) return;

  try {
    final res = await http.post(
      Uri.parse(WorkerApi.pushMessageUrl),
      headers: await WorkerApi.headers(),
      body: jsonEncode({
        'chatId': chatId,
        if (messageId != null) 'messageId': messageId,
        'preview': messageBody,
      }),
    );
    if (res.statusCode == 404 && !res.body.contains('"error"')) {
      // The Worker hasn't been redeployed with /push/message yet.
      await _sendViaOldRelay(
        otherUid: otherUid,
        chatId: chatId,
        senderName: senderName,
        messageBody: messageBody,
        senderUid: senderUid,
      );
    } else if (res.statusCode >= 300) {
      debugPrint('Chat push: HTTP ${res.statusCode} ${res.body}');
    }
  } catch (e) {
    // Best-effort — a failed push shouldn't block sending the message.
    debugPrint('Chat push failed: $e');
  }
}

/// TRANSITION ONLY: the pre-/push/message relay. Delete once the new Worker
/// is live.
Future<void> _sendViaOldRelay({
  required String otherUid,
  required String chatId,
  required String senderName,
  required String messageBody,
  required String senderUid,
}) async {
  final snapshot =
      await FirebaseDatabase.instance.ref('users/$otherUid/oneSignalId').get();
  final playerId = snapshot.value as String?;
  if (playerId == null || playerId.isEmpty) return;

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
}
