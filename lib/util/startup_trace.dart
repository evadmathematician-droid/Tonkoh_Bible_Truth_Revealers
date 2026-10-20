import 'package:flutter/foundation.dart';

/// Startup timeline in the device log ("[Startup] +123 ms firstFrame"), so
/// cold-start and resume times can be read with `adb logcat -s flutter`.
/// Times are from the start of Dart's main().
class StartupTrace {
  StartupTrace._();

  static final Stopwatch _clock = Stopwatch()..start();
  static final Set<String> _once = {};

  static int get elapsedMs => _clock.elapsedMilliseconds;

  static void mark(String label) {
    debugPrint('[Startup] +${_clock.elapsedMilliseconds} ms $label');
  }

  /// Like [mark], but only the first time [label] is reached.
  static void markOnce(String label) {
    if (_once.add(label)) mark(label);
  }
}
