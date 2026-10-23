import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// The one Cloudflare Worker the app talks to (push relay, call push, TURN
/// credentials, account migration). Every call site builds its URL and
/// auth from here instead of carrying its own copy.
class WorkerApi {
  WorkerApi._();

  static const String baseUrl =
      'https://small-dream-b231.tonkohbibletruthrevealers.workers.dev';

  static const String sendPushUrl = '$baseUrl/send-push';
  static const String sendCallPushUrl = '$baseUrl/send-call-push';

  /// Verified chat / call pushes: the Worker works out the receiver from
  /// the chat or call and the caller's Firebase ID token.
  static const String pushMessageUrl = '$baseUrl/push/message';
  static const String pushCallUrl = '$baseUrl/push/call';
  static const String migrationVerifyUrl = '$baseUrl/migration-verify';
  static const String turnCredentialsUrl = baseUrl;

  // TRANSITION ONLY. The Worker now authorises requests by the caller's
  // Firebase ID token (see cloudflare/worker_full.js verifyFirebaseIdToken).
  // This old shared secret is still sent so builds keep working against a
  // Worker that hasn't been redeployed yet. Once the new Worker is live and
  // every install is on a build that sends the token, set the Worker's
  // ALLOW_LEGACY_SECRET=false (or rotate RELAY_SECRET) and delete this.
  static const String legacySecret = 'test-relay-secret-123';

  /// JSON headers plus `Authorization: Bearer <Firebase ID token>` when a
  /// user is signed in. Never throws — a missing token just falls back to
  /// the legacy secret in the body during the transition.
  static Future<Map<String, String>> headers() async {
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
    };
    try {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    } catch (e) {
      debugPrint('WorkerApi: getIdToken failed: $e');
    }
    return headers;
  }
}
