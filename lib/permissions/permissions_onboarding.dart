import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One-time, upfront Android runtime permission request fired right after a
/// user finishes phone-number registration (see `AuthGate`).
///
/// The owner wants a predictable flow: as the user first lands on the home
/// screen, prompt in sequence, one system dialog after another:
///   1. Phone       (`READ_PHONE_STATE` — SIM contacts, call routing)
///   2. Camera      (video calls)
///   3. Microphone  (`RECORD_AUDIO` — calls, voice notes)
///   4. Ignore battery optimization — so a high-priority incoming-call FCM
///      push isn't delayed/dropped by Doze while the phone sleeps. This one
///      can't be granted silently (the intent always shows a system
///      dialog), so it's asked here with the rest.
///
/// Denial does **not** block app usage — each feature still re-prompts
/// lazily at its point of use (call screens, voice recorder, contacts
/// screen) as a safety net. On very aggressive OEMs (Xiaomi/Transsion/etc.)
/// the user additionally has to enable "Autostart" / "Protected apps"
/// manually — no app can do that programmatically; see
/// `lib/calls/call_reliability_tips.dart`.
///
/// Android only. Web browsers prompt per use; iOS goes through its own
/// plugin flow. The whole thing runs at most once per registration, guarded
/// by a persisted flag.
class PermissionsOnboarding {
  PermissionsOnboarding._();

  // v2: adds the battery-optimization step. Existing users get that one new
  // dialog on next launch; the three already-granted permissions re-request
  // silently (no dialog for an already-granted permission).
  static const _flagKey = 'perms_onboarded_v2';

  /// Ordered so the calling feature's permissions come first, battery
  /// optimization last.
  static const _sequence = <Permission>[
    Permission.phone,
    Permission.camera,
    Permission.microphone,
    Permission.ignoreBatteryOptimizations,
  ];

  /// Requests the onboarding permissions in sequence, exactly once. Safe to
  /// call unconditionally from the post-registration path — it no-ops on
  /// web / non-Android and on every call after the first.
  static Future<void> maybeRunAfterRegistration() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_flagKey) == true) return;

    for (final permission in _sequence) {
      try {
        final status = await permission.request();
        debugPrint('PermissionsOnboarding: $permission -> $status');
      } catch (e) {
        // A single permission failing (or being unavailable on this device)
        // must not abort the rest of the sequence.
        debugPrint('PermissionsOnboarding: $permission request failed: $e');
      }
    }

    // Mark done regardless of grant/deny — this is "asked once per
    // registration", not "granted". Feature-level prompts handle the rest.
    await prefs.setBool(_flagKey, true);
  }

  /// Re-run just the battery-optimization ask (e.g. from a "calls not
  /// working?" settings entry).
  static Future<void> askBatteryOptimizationAgain() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {}
  }
}
