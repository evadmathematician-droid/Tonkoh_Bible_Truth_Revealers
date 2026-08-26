import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';

/// Wraps Google Play's own in-app update API (Play Core) — the same
/// mechanism the previous native MainActivity used via
/// com.google.android.play:app-update. Android + Play Store only; every
/// caller here already guards on that before touching this class.
class PlayUpdateService {
  static Future<bool> immediateUpdateAvailable() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final info = await InAppUpdate.checkForUpdate();
      return info.updateAvailability == UpdateAvailability.updateAvailable &&
          info.immediateUpdateAllowed;
    } catch (e) {
      // No Play Store on this device (sideload, other store, emulator
      // without Play services) — not an error, just means this path
      // doesn't apply and the Firebase-based check takes over instead.
      debugPrint('PlayUpdateService: checkForUpdate unavailable: $e');
      return false;
    }
  }

  /// Launches Play's full-screen, system-drawn immediate-update UI. On
  /// success Play installs the update and restarts the app itself, so this
  /// call normally never returns. Returns false if the user backs out or
  /// the flow fails, so the caller can fall back to the Play Store listing.
  static Future<bool> performImmediateUpdate() async {
    try {
      final result = await InAppUpdate.performImmediateUpdate();
      return result == AppUpdateResult.success;
    } catch (e) {
      debugPrint('PlayUpdateService: performImmediateUpdate failed: $e');
      return false;
    }
  }
}
