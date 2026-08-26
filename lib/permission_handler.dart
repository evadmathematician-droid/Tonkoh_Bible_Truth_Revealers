import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Port of the native MainActivity's requestCorePermissionsIfNeeded().
///
/// Requests Camera, Microphone, Phone State, Notifications (Android 13+),
/// and Bluetooth Connect (Android 12+) together in ONE combined system
/// dialog — matching the native app's behavior where these were requested
/// as a single ActivityResultContracts.RequestMultiplePermissions() call.
///
/// Call this once, right after registration/profile setup succeeds — NOT
/// lazily at call time. (Individual screens like OutgoingCallScreen and
/// OngoingCallScreen still request camera/mic again right before a call as
/// a safety net in case the user denied here or revoked later — that's
/// fine and expected; permission_handler's request() is a no-op prompt if
/// already granted, it just confirms status.)
///
/// No native Kotlin needed for this — permission_handler already talks to
/// the same underlying Android permission APIs the native code called
/// directly.
class CorePermissions {
  CorePermissions._();

  static Future<Map<Permission, PermissionStatus>> requestAfterRegistration() async {
    if (kIsWeb) {
      // Browser permission prompts are handled per-getUserMedia-call by
      // the browser itself — there's no equivalent combined native dialog
      // to trigger up front on web.
      return {};
    }

    final permissions = <Permission>[
      Permission.camera,
      Permission.microphone,
      Permission.phone, // maps to READ_PHONE_STATE on Android
    ];

    if (Platform.isAndroid) {
      // permission_handler's Permission.notification and
      // Permission.bluetoothConnect are safe to request on all Android
      // versions — the plugin itself no-ops/auto-grants on OS versions
      // below where each permission was introduced (13+ for
      // notifications, 12+ for bluetoothConnect), so no manual SDK-level
      // branching is needed the way the native Kotlin code had to do with
      // Build.VERSION.SDK_INT checks.
      permissions.add(Permission.notification);
      permissions.add(Permission.bluetoothConnect);
    }

    final results = await permissions.request();

    for (final entry in results.entries) {
      debugPrint('CorePermissions: ${entry.key} => ${entry.value}');
    }

    return results;
  }
}