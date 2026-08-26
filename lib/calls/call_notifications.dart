import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class CallNotificationAction {
  final String action; // open | accept | decline | end
  final String callId;
  final String? callType;
  final String? callerName;

  CallNotificationAction({
    required this.action,
    required this.callId,
    this.callType,
    this.callerName,
  });
}

class CallNotifications {
  static const String _channelIncoming = 'incoming_call_channel';
  static const String _channelRecording = 'voice_recording_channel';

  static const int _notifIdIncoming = 4241;
  static const int _notifIdRecording = 4243;

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static final StreamController<CallNotificationAction> _actionController =
  StreamController<CallNotificationAction>.broadcast();

  static Stream<CallNotificationAction> get actionStream => _actionController.stream;

  /// Lets other entry points (e.g. the native Telecom hand-off in
  /// NativeCallBridge) replay an accept/decline through the exact same
  /// stream your existing UI already listens to for the local notification's
  /// own Accept/Decline buttons — instead of duplicating that logic.
  static void emitAction(CallNotificationAction action) {
    _actionController.add(action);
  }

  static Future<void> init() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationAction,
      onDidReceiveBackgroundNotificationResponse: _onNotificationAction,
    );
  }

  static void _onNotificationAction(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || !payload.startsWith('call:')) return;

    final parts = payload.split(':');
    if (parts.length < 3) return;

    // response.actionId is set when the user tapped one of the explicit
    // Accept/Decline/End buttons (values 'accept' | 'decline' | 'end').
    // If they tapped the notification BODY instead, actionId is null —
    // that used to fall back to parts[1], which was the literal string
    // "action" (a payload-format placeholder, not a real action), so it
    // matched no case in the switch in main.dart and did nothing. Default
    // that case to 'open' instead: it means "bring the user to the call
    // screen without auto-accepting or auto-declining."
    final action = response.actionId ?? 'open';
    final callId = parts[2];
    final callType = parts.length > 3 ? parts[3] : null;
    final callerName = parts.length > 4 ? parts[4] : null;

    _actionController.add(CallNotificationAction(
      action: action,
      callId: callId,
      callType: callType,
      callerName: callerName,
    ));
  }

  static Future<void> showIncomingCall({
    required String callId,
    required String callType,
    required String callerName,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      _channelIncoming,
      'Incoming Calls',
      channelDescription: 'Ringing screen for incoming TBTR calls',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      timeoutAfter: 30000,
      // No custom ringtone resource shipped yet (android/app/src/main/res/raw/
      // doesn't exist in this project) — leaving `sound` unset falls back to
      // the system default notification sound instead of silently failing.
      // Drop a real file at res/raw/ringtone.mp3 and restore
      // `sound: const RawResourceAndroidNotificationSound('ringtone')` once one exists.
      vibrationPattern: Int64List.fromList([0, 800, 500, 800]),
      actions: const [
        AndroidNotificationAction(
          'decline',
          'Decline',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'accept',
          'Accept',
          showsUserInterface: true,
          cancelNotification: true,
        ),
      ],
    );

    // NOTE: this payload's second segment is just a format placeholder,
    // not a real action — the actual action always comes from
    // response.actionId (button tap) or defaults to 'open' (body tap).
    // See _onNotificationAction above.
    await _plugin.show(
      _notifIdIncoming,
      callType == 'video' ? 'Incoming video call' : 'Incoming voice call',
      callerName,
      NotificationDetails(android: androidDetails),
      payload: 'call:open:$callId:$callType:$callerName',
    );
  }

  static Future<void> showRecordingNotification() async {
    final androidDetails = AndroidNotificationDetails(
      _channelRecording,
      'Voice Recording',
      channelDescription: 'Recording voice message',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
    );
    await _plugin.show(
      _notifIdRecording,
      'Recording voice message',
      null,
      NotificationDetails(android: androidDetails),
    );
  }

  static Future<void> cancelIncoming() => _plugin.cancel(_notifIdIncoming);
  static Future<void> cancelRecording() => _plugin.cancel(_notifIdRecording);
}