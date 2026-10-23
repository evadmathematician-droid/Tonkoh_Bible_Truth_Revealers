import 'package:flutter/material.dart';
import '../calls/incoming_call_screen.dart';
import '../calls/ongoing_call_screen.dart';
import '../calls/outgoing_call_screen.dart';

class CallNavigator {
  static final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();

  static BuildContext? get context => key.currentContext;

  /// True while an incoming / outgoing / in-call screen is open.
  static bool get inCall => _CallRoute.live > 0;

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
      _CallRoute(
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
    required String callerUid,
    required String callerName,
    required String calleeUid,
    required String calleeName,
    required String callType,
  }) async {
    final ctx = context;
    if (ctx == null) return null;
    return Navigator.of(ctx).push<T>(
      _CallRoute(
        builder: (_) => OutgoingCallScreen(
          callId: callId,
          callerUid: callerUid,
          callerName: callerName,
          calleeUid: calleeUid,
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
      _CallRoute(
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

  /// Leave every call screen and return to the app's home (route 0 =
  /// AuthGate). Used by all call screens on hang-up / decline / remote-end
  /// instead of a bare `Navigator.pop()`.
  ///
  /// Why not `pop()`: the call screens are pushed on the root navigator,
  /// whose stack is normally just `[AuthGate, <call screen>]`. A plain
  /// `pop()` there is usually fine, but if the call screen ever ends up as
  /// the only route (answered from a notification before AuthGate mounted,
  /// an unusual restore) `pop()` on the last route makes Android finish the
  /// task — the app "closes" on hang-up. `popUntil(isFirst)` returns to
  /// AuthGate when it's there and is a harmless no-op when it isn't, so the
  /// app can never exit this way.
  static void leaveCall() {
    final ctx = context;
    if (ctx == null) return;
    final nav = Navigator.of(ctx);
    if (nav.canPop()) nav.popUntil((r) => r.isFirst);
  }

  /// Replace whatever call screen is showing (incoming / outgoing) with the
  /// in-call screen — used when a call is answered from the notification, so
  /// hanging up later returns straight to AuthGate, not to a stale ringing
  /// screen.
  static Future<T?> replaceWithOngoingCall<T>({
    required String callId,
    required String callType,
    required bool isCaller,
    required String peerName,
  }) async {
    final ctx = context;
    if (ctx == null) return null;
    return Navigator.of(ctx).pushAndRemoveUntil<T>(
      _CallRoute(
        builder: (_) => OngoingCallScreen(
          callId: callId,
          callType: callType,
          isCaller: isCaller,
          peerName: peerName,
        ),
      ),
      (r) => r.isFirst,
    );
  }
}

/// A call screen's route. Counts the ones on screen for
/// [CallNavigator.inCall]; dispose runs however the route goes away.
class _CallRoute<T> extends MaterialPageRoute<T> {
  _CallRoute({required super.builder}) : super(fullscreenDialog: true);

  static int live = 0;

  @override
  void install() {
    super.install();
    live++;
  }

  @override
  void dispose() {
    live--;
    super.dispose();
  }
}