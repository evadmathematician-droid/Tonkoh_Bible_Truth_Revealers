import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class CallNotificationAction {
  final String action; // accept | decline | end
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
  // v3: the notification is now SILENT (no sound, no vibration) — the ring
  // audio is a native looping MediaPlayer and the ring vibration is a Dart
  // loop, both owned by IncomingCallManager. A channel's sound/vibration are
  // immutable once created, so a new id is the only way to drop the old
  // insistent-ring behaviour on devices that already have the v2 channel.
  // The older ids are deleted in [init].
  static const String _channelIncoming = 'incoming_call_channel_v3';
  static const List<String> _channelIncomingLegacy = <String>[
    'incoming_call_channel',
    'incoming_call_channel_v2',
  ];
  static const String _channelOngoing = 'ongoing_call_channel';
  static const String _channelRecording = 'voice_recording_channel';

  static const int _notifIdIncoming = 4241;
  static const int _notifIdOngoing = 4242;
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

  /// flutter_local_notifications ships no web plugin — every method channel
  /// call throws there. All public entry points below no-op on web; the
  /// in-app call screens ([IncomingCallScreen] / [OngoingCallScreen]) are the
  /// call UI on that platform.
  static bool get _unsupported => kIsWeb;

  static Future<void> init() async {
    if (_unsupported) return;
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationAction,
      onDidReceiveBackgroundNotificationResponse: _onNotificationAction,
    );

    // Drop the older incoming-call channels so they don't linger in system
    // settings with their old insistent-ring behaviour.
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      for (final id in _channelIncomingLegacy) {
        await android?.deleteNotificationChannel(id);
      }
    } catch (e) {
      debugPrint('CallNotifications: legacy channel cleanup skipped: $e');
    }
  }

  static void _onNotificationAction(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || !payload.startsWith('call:')) return;

    final parts = payload.split(':');
    if (parts.length < 3) return;

    final action = response.actionId ?? parts[1];
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

  static const _incomingActions = <AndroidNotificationAction>[
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
  ];

  static AndroidNotificationDetails _incomingCallDetails() {
    return AndroidNotificationDetails(
      _channelIncoming,
      'Incoming Calls',
      channelDescription: 'Ringing screen for incoming TBTR calls',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      // Match IncomingCallManager's 45 s no-answer auto-decline so the
      // ring doesn't die early (was 30 s).
      timeoutAfter: 45000,
      // The ringtone AUDIO and the ring VIBRATION are both driven by
      // IncomingCallManager — a looping native MediaPlayer on the ring
      // stream (IncomingRingtone) and a looping Vibration pattern. The
      // notification's own sound/vibration are turned off here: relying on
      // FLAG_INSISTENT to loop a notification sound was silent on the
      // Transsion/Infinix OEM builds this app targets (vibrated 40 s, no
      // sound), which is the bug this replaces.
      playSound: false,
      enableVibration: false,
      actions: _incomingActions,
    );
  }

  static Future<void> showIncomingCall({
    required String callId,
    required String callType,
    required String callerName,
  }) async {
    if (_unsupported) return;

    final title =
        callType == 'video' ? 'Incoming video call' : 'Incoming voice call';
    final payload = 'call:action:$callId:$callType:$callerName';

    try {
      await _plugin.show(
        _notifIdIncoming,
        title,
        callerName,
        NotificationDetails(android: _incomingCallDetails()),
        payload: payload,
      );
    } catch (e) {
      // The notification is silent now (ring audio + vibration are driven by
      // IncomingCallManager), so there's no sound to fall back to — just log
      // and let the in-app ringing screen carry the call.
      debugPrint(
          'CallNotifications: incoming-call notification failed: $e');
    }
  }

  static Future<void> showOngoingCall({
    required String callType,
    required String peerName,
    required String statusText,
  }) async {
    if (_unsupported) return;
    final androidDetails = AndroidNotificationDetails(
      _channelOngoing,
      'Ongoing Calls',
      channelDescription: 'Active TBTR call',
      importance: Importance.low,
      priority: Priority.low,
      category: AndroidNotificationCategory.call,
      ongoing: true,
      actions: const [
        AndroidNotificationAction(
          'end',
          'End',
          showsUserInterface: true,
          cancelNotification: true,
        ),
      ],
    );

    await _plugin.show(
      _notifIdOngoing,
      callType == 'video' ? 'Video call' : 'Voice call',
      '$peerName • $statusText',
      NotificationDetails(android: androidDetails),
      payload: 'call:end:ongoing',
    );
  }

  static const String _channelMissed = 'missed_call_channel';
  static const int _notifIdMissedBase = 4250;

  /// A "Missed call from X" alert, shown to the person who didn't answer.
  /// Distinct id per chat so two different missed callers don't overwrite
  /// each other. Tapping it just opens the app.
  static Future<void> showMissedCall({
    required String callerName,
    required String callType,
    required String chatId,
  }) async {
    if (_unsupported) return;
    final androidDetails = AndroidNotificationDetails(
      _channelMissed,
      'Missed Calls',
      channelDescription: 'Alerts for calls you missed',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.missedCall,
      autoCancel: true,
    );
    final id = _notifIdMissedBase + (chatId.hashCode & 0x7fff);
    try {
      await _plugin.show(
        id,
        callType == 'video' ? 'Missed video call' : 'Missed voice call',
        callerName.isEmpty ? 'Someone called you' : callerName,
        NotificationDetails(android: androidDetails),
        payload: 'missed:$chatId',
      );
    } catch (e) {
      debugPrint('CallNotifications: showMissedCall failed: $e');
    }
  }

  static Future<void> showRecordingNotification() async {
    if (_unsupported) return;
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

  static Future<void> cancelIncoming() async {
    if (_unsupported) return;
    await _plugin.cancel(_notifIdIncoming);
  }

  static Future<void> cancelOngoing() async {
    if (_unsupported) return;
    await _plugin.cancel(_notifIdOngoing);
  }

  static Future<void> cancelRecording() async {
    if (_unsupported) return;
    await _plugin.cancel(_notifIdRecording);
  }
}