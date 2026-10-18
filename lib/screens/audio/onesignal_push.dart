import 'package:http/http.dart' as http;
import 'dart:convert';

import '../../config/worker_api.dart';

// Relayed through the same Cloudflare Worker /send-push route
// private_chat_push.dart uses, instead of embedding the OneSignal REST API
// key in client code — see cloudflare/worker_full.js. Broadcasting to
// everyone uses the "segments" field (the Worker falls back to
// included_segments when no specific subscriptionIds are given) rather than
// a separate endpoint. The Worker authorises the call by the sender's
// Firebase ID token (WorkerApi.headers).

/// Equivalent of sendAudioPushNotification(). Fire-and-forget, broadcasts
/// to all users (senders included), matching the Kotlin behavior.
Future<void> sendAudioPushNotification({
  required String senderName,
  required String messageBody,
  required String senderUid,
  String heading = 'New message',
}) async {
  try {
    final res = await http.post(
      Uri.parse(WorkerApi.sendPushUrl),
      headers: await WorkerApi.headers(),
      body: jsonEncode({
        'secret': WorkerApi.legacySecret,
        'segments': ['All'],
        'heading': heading,
        'content': '$senderName: $messageBody',
        // body lets the receiving phone rebuild the text with its own
        // contact name for the sender (CallNotificationServiceExtension.kt).
        'data': {
          'type': 'audio_message',
          'senderUid': senderUid,
          'body': messageBody,
        },
        'smallIcon': 'ic_notification_logo',
        'largeIcon': 'ic_notification_logo',
      }),
    );
    if (res.statusCode >= 300) {
      // ignore: avoid_print
      print('Push relay error: ${res.body}');
    }
  } catch (e) {
    // ignore: avoid_print
    print('Push relay failed: $e');
  }
}
