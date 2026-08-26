import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Runs a top-level entry point so the platform side can re-attach a task
/// handler to this isolate after process restarts. Required by the plugin
/// to be top-level/static and `@pragma('vm:entry-point')`.
@pragma('vm:entry-point')
void _callForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_CallTaskHandler());
}

/// Nothing to actually do on a repeating timer here — this task exists
/// purely to hold a foreground service open for the duration of a call, not
/// to perform periodic background work. Button presses are the only thing
/// that need forwarding back to the main isolate.
class _CallTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'end_call') {
      FlutterForegroundTask.sendDataToMain('end_call');
    }
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.sendDataToMain('open_call');
  }
}

/// Keeps the process alive for the duration of an active call using
/// Android's standard foreground-service mechanism — the same approach
/// WhatsApp/Signal/Telegram use. Deliberately NOT the battery-optimization-
/// exemption route: that requires an explicit "Allow" system dialog.
/// FOREGROUND_SERVICE is a normal, install-time-granted permission — the
/// only thing the user sees is the persistent call notification itself,
/// which is expected and standard during an active call, no extra prompt.
class CallForegroundService {
  CallForegroundService._();

  static bool _initialized = false;

  /// Call once at app startup, before any call can start.
  static void init() {
    if (kIsWeb || !Platform.isAndroid || _initialized) return;
    _initialized = true;

    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ongoing_call_foreground',
        channelName: 'Ongoing Call',
        channelDescription: 'Keeps your call connected while the app is in the background.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Nothing needs to run on a repeating timer — this service exists
        // solely to keep the call alive, not to poll for anything.
        // ForegroundTaskEventAction.nothing() is a plain (non-const)
        // factory, so this whole options object can't be const either.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> start({required String title, required String text}) async {
    if (kIsWeb || !Platform.isAndroid) return;

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: 331,
      notificationTitle: title,
      notificationText: text,
      notificationButtons: const [NotificationButton(id: 'end_call', text: 'End')],
      callback: _callForegroundTaskCallback,
    );
  }

  static Future<void> update({required String title, required String text}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
    }
  }

  static Future<void> stop() async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
