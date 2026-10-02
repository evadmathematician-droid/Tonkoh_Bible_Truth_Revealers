import 'package:dio/dio.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'platform_call_support.dart';

class CallInitiator {
  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final Dio _dio = Dio();

  static const String _pushRelayUrl =
      'https://small-dream-b231.tonkohbibletruthrevealers.workers.dev/send-call-push';
  static const String _pushRelaySecret = 'test-relay-secret-123';

  // ── Idempotency guard (duplicate-dial bug) ───────────────────────────────
  // A single tap on a call button occasionally reaches [initiateCall] twice
  // (a bounced tap, a rebuild re-firing the handler, or two overlapping
  // gesture recognisers). Each pass would `_db.ref('calls').push()` a fresh
  // node, so the callee gets two "incoming call" events for one tap. Remember
  // the last caller→callee→type we dialled and swallow a repeat within a
  // short window. Static so it holds across the throwaway `CallInitiator()`
  // instances that each call site creates.
  static String? _lastDialKey;
  static DateTime? _lastDialAt;
  static const Duration _dialDedupeWindow = Duration(seconds: 6);

  Future<void> initiateCall({
    required String callerUid,
    required String callerName,
    String callerPhoto = '',
    required String calleeUid,
    required String chatId,
    required String callType,
    required void Function(String callId) onCallIdReady,
  }) async {
    // FIX (duplicate outgoing call bug): Android places outgoing calls
    // through TelecomCallManager.placeOutgoingCall() natively (Kotlin
    // CallSignaling.initiateCall), which writes the "calls" record AND
    // registers the call with Telecom for proper audio focus/routing and
    // call-log integration. If Android's UI ever calls this Dart method
    // directly, it must be a no-op — otherwise you get two separate
    // "calls/{id}" records for one tap, and only one of them is wired to
    // Telecom. Android should invoke the native path via a MethodChannel
    // instead of calling this method at all.
    if (callsHandledNatively) {
      debugPrint(
          'CallInitiator: skipped — Android places calls via TelecomCallManager natively');
      return;
    }

    final dialKey = '$callerUid|$calleeUid|$callType';
    final now = DateTime.now();
    if (_lastDialKey == dialKey &&
        _lastDialAt != null &&
        now.difference(_lastDialAt!) < _dialDedupeWindow) {
      debugPrint(
          'CallInitiator: ignoring duplicate initiateCall for $dialKey '
          '(${now.difference(_lastDialAt!).inMilliseconds}ms after the last)');
      return;
    }
    _lastDialKey = dialKey;
    _lastDialAt = now;

    final ref = _db.ref('calls').push();
    final callId = ref.key!;
    if (callId.isEmpty) return;

    final callMap = <String, dynamic>{
      'callId': callId,
      'callerId': callerUid,
      'callerName': callerName,
      'callerPhoto': callerPhoto,
      'calleeId': calleeUid,
      'chatId': chatId,
      'type': callType,
      'state': 'RINGING',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };

    await ref.set(callMap);
    debugPrint('CallSignaling: Call doc created: $callId');
    onCallIdReady(callId);

    _trySendCallPush(calleeUid, callerName, callMap);
  }

  Future<void> _trySendCallPush(
      String calleeUid,
      String callerName,
      Map<String, dynamic> callData,
      ) async {
    try {
      final snap = await _db.ref('users').child(calleeUid).child('oneSignalId').get();
      final subId = snap.value as String?;
      if (subId == null || subId.isEmpty) {
        debugPrint('CallSignaling: No OneSignal ID — relying on Firebase RTDB only');
        return;
      }

      final body = <String, dynamic>{
        'secret': _pushRelaySecret,
        'oneSignalId': subId,
        'callId': callData['callId'],
        'callerId': callData['callerId'],
        'callerName': callerName,
        'callerPhoto': callData['callerPhoto'],
        'callType': callData['type'],
        'chatId': callData['chatId'],
      };

      final response = await _dio.post(
        _pushRelayUrl,
        data: body,
        options: Options(
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );

      if (response.statusCode == 200) {
        debugPrint('CallSignaling: Push relay call OK');
      } else {
        debugPrint('CallSignaling: Push relay HTTP ${response.statusCode}');
      }
    } on DioException catch (e) {
      debugPrint('CallSignaling: Push relay failed (network): ${e.message}');
    } catch (e) {
      debugPrint('CallSignaling: Push relay failed: $e');
    }
  }
}