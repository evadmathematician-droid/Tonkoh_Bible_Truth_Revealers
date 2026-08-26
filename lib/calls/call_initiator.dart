import 'package:dio/dio.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'call_models.dart';

class CallInitiator {
  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final Dio _dio = Dio();

  static const String _pushRelayUrl =
      'https://small-dream-b231.tonkohbibletruthrevealers.workers.dev/send-call-push';
  static const String _pushRelaySecret = 'test-relay-secret-123';

  Future<void> initiateCall({
    required String callerUid,
    required String callerName,
    String callerPhoto = '',
    required String calleeUid,
    required String chatId,
    required String callType,
    required void Function(String callId) onCallIdReady,
  }) async {
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