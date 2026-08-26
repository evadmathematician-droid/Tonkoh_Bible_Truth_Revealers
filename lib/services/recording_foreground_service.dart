import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void _recordingForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_RecordingTaskHandler());
}

class _RecordingTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

/// Keeps the microphone session alive while recording a voice note and the
/// app is backgrounded. Android suspends mic access for backgrounded apps
/// unless a foreground service with the "microphone" type is actively
/// running — nothing protected VoiceRecorderService's AudioRecorder before
/// this, so leaving the app mid-recording silently killed the recording.
///
/// Reuses the flutter_foreground_task plugin already initialized once in
/// main.dart (CallForegroundService.init()) and the same manifest service
/// declaration (already typed "microphone|camera") — no new init or
/// manifest change needed, just a second start/stop entry point for a
/// different call-site.
class RecordingForegroundService {
  RecordingForegroundService._();

  static Future<void> start() async {
    if (kIsWeb || !Platform.isAndroid) return;

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Recording voice message',
        notificationText: 'Tap to return to the app',
      );
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: 442,
      notificationTitle: 'Recording voice message',
      notificationText: 'Tap to return to the app',
      callback: _recordingForegroundTaskCallback,
    );
  }

  static Future<void> stop() async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
