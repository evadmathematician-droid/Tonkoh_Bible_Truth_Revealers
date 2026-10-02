import 'package:http/http.dart' as http;
import 'dart:convert';

// Relayed through the same Cloudflare Worker /send-push route
// private_chat_push.dart uses, instead of embedding the OneSignal REST API
// key in client code — see cloudflare-worker/push-relay-worker.js.
// Broadcasting to everyone uses the "segments" field (the Worker falls back
// to included_segments when no specific subscriptionIds are given) rather
// than a separate endpoint. Only this low-value shared secret ships
// client-side.
const _pushRelayUrl =
    'https://small-dream-b231.tonkohbibletruthrevealers.workers.dev/send-push';
const _pushRelaySecret = 'test-relay-secret-123'; // must match RELAY_SECRET set in the Worker

/// Equivalent of sendAudioPushNotification(). Fire-and-forget, broadcasts
/// to all users (senders included), matching the Kotlin behavior.
Future<void> sendAudioPushNotification({
  required String senderName,
  required String messageBody,
  required String senderUid,
}) async {
  try {
    final res = await http.post(
      Uri.parse(_pushRelayUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'secret': _pushRelaySecret,
        'segments': ['All'],
        'heading': 'New message',
        'content': '$senderName: $messageBody',
        'data': {'type': 'audio_message', 'senderUid': senderUid},
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
