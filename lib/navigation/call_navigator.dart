import 'package:flutter/material.dart';
import '../calls/incoming_call_screen.dart';
import '../calls/ongoing_call_screen.dart';
import '../calls/outgoing_call_screen.dart';

class CallNavigator {
  static final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();

  static BuildContext? get context => key.currentContext;

  static Future<T?> toIncomingCall<T>({
    required String callId,
    required String callerId,
    required String callerName,
    String callerPhoto = '',
    required String chatId,
    required String callType,
  }) async {
    final ctx = context;
    if (ctx == null) return null;
    return Navigator.of(ctx).push<T>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => IncomingCallScreen(
          callId: callId,
          callerId: callerId,
          callerName: callerName,
          callerPhoto: callerPhoto,
          chatId: chatId,
          callType: callType,
        ),
      ),
    );
  }

  static Future<T?> toOutgoingCall<T>({
    required String callId,
    required String calleeName,
    required String callType,
  }) async {
    final ctx = context;
    if (ctx == null) return null;
    return Navigator.of(ctx).push<T>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => OutgoingCallScreen(
          callId: callId,
          calleeName: calleeName,
          callType: callType,
        ),
      ),
    );
  }

  static Future<T?> toOngoingCall<T>({
    required String callId,
    required String callType,
    required bool isCaller,
    required String peerName,
  }) async {
    final ctx = context;
    if (ctx == null) return null;
    return Navigator.of(ctx).push<T>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => OngoingCallScreen(
          callId: callId,
          callType: callType,
          isCaller: isCaller,
          peerName: peerName,
        ),
      ),
    );
  }

  static void pop() {
    final ctx = context;
    if (ctx == null) return;
    Navigator.of(ctx).pop();
  }
}