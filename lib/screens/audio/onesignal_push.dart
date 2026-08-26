import 'package:http/http.dart' as http;
import 'dart:convert';

const String _pushRelayUrl =
    'https://small-dream-b231.tonkohbibletruthrevealers.workers.dev/send-push';
const String _pushRelaySecret = 'test-relay-secret-123'; // must match RELAY_SECRET set in the Worker's env

/// Equivalent of sendAudioPushNotification(). Fire-and-forget, broadcasts
/// to all users (senders included), matching the Kotlin behavior.
///
/// Sent via the Cloudflare Worker relay instead of calling OneSignal's REST
/// API directly — the real OneSignal REST key lives only in the Worker's
/// env (ONESIGNAL_REST_API_KEY), never in client code. Was previously a
/// direct api.onesignal.com call with a hardcoded key here; that key got
/// flagged and blocked by GitHub push protection.
///
/// NOTE: this broadcasts via `segments: ['All']`, which requires the
/// Worker's /send-push route to pass an `included_segments` field through
/// to OneSignal — add that support to the Worker before relying on this.
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
      print('OneSignal push relay error: ${res.body}');
    }
  } catch (e) {
    // ignore: avoid_print
    print('OneSignal push relay failed: $e');
  }
}
