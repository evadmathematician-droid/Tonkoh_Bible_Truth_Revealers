import 'dart:io' show Platform;

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/web_onesignal_bridge.dart'
    if (dart.library.io) '../services/web_onesignal_bridge_stub.dart';

import 'linked_device.dart';

enum DeviceRegistrationResult {
  /// Device row exists (created or already present) and is up to date.
  active,

  /// This device had previously registered itself, but its row is now
  /// missing from the backend — i.e. it was unlinked from Settings on
  /// (possibly) another device. The caller should treat this as a forced
  /// sign-out.
  unlinkedRemotely,

  /// No push-subscription id available yet (e.g. OneSignal hasn't
  /// finished registering this install) — nothing to do this call.
  skipped,
}

/// Backend layer for the Settings screen's "Linked Devices" section.
/// Follows the same repository shape/naming as CallSignalingRepository —
/// a thin class wrapping FirebaseDatabase reads/writes for one concern.
///
/// There's no prior "linked devices" concept anywhere in this codebase
/// (confirmed by exhaustive search before writing this), so this is new
/// data modeling, not a port of something pre-existing: one row per
/// device under `users/{phone}/devices/{deviceId}`, keyed by that
/// device's OneSignal push-subscription id (already assigned to every
/// install via the existing OneSignal integration, so no new
/// device-identifier plugin/permission is needed).
class UserDeviceRepository {
  DatabaseReference _devicesRef(String phoneKey) =>
      FirebaseDatabase.instance.ref('users').child(phoneKey).child('devices');

  static const _registeredFlagPrefix = 'device_registered_';

  Future<String?> currentDeviceId() async {
    if (kIsWeb) return WebOneSignalBridge.getSubscriptionId();
    return OneSignal.User.pushSubscription.id;
  }

  String _currentPlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return Platform.operatingSystem;
  }

  /// Registers/heartbeats the current device under the signed-in user's
  /// account. Call this once per app launch (AuthGate._setReady), same
  /// trigger point as the incoming-call listener and contacts sync.
  ///
  /// Distinguishes "first time ever seeing this device" (creates the row)
  /// from "this device was previously registered but its row is gone now"
  /// (returns unlinkedRemotely instead of silently re-creating it) via a
  /// local per-device flag — otherwise "unlink" from Settings would be
  /// meaningless, since the very next launch would just re-add the device.
  Future<DeviceRegistrationResult> registerCurrentDevice(String phoneKey) async {
    try {
      final deviceId = await currentDeviceId();
      if (deviceId == null || deviceId.isEmpty) return DeviceRegistrationResult.skipped;

      final ref = _devicesRef(phoneKey).child(deviceId);
      final now = DateTime.now().millisecondsSinceEpoch;
      final existing = await ref.get();

      if (existing.exists) {
        await ref.update({'lastActiveAt': now});
        return DeviceRegistrationResult.active;
      }

      final prefs = await SharedPreferences.getInstance();
      final flagKey = '$_registeredFlagPrefix$deviceId';
      final wasRegisteredBefore = prefs.getBool(flagKey) ?? false;
      if (wasRegisteredBefore) {
        return DeviceRegistrationResult.unlinkedRemotely;
      }

      await ref.set(LinkedDevice(
        deviceId: deviceId,
        platform: _currentPlatform(),
        createdAt: now,
        lastActiveAt: now,
      ).toMap());
      await prefs.setBool(flagKey, true);
      return DeviceRegistrationResult.active;
    } catch (e) {
      debugPrint('UserDeviceRepository: registerCurrentDevice failed: $e');
      return DeviceRegistrationResult.skipped;
    }
  }

  Future<List<LinkedDevice>> fetchDevices(String phoneKey) async {
    try {
      final snapshot = await _devicesRef(phoneKey).get();
      if (!snapshot.exists || snapshot.value is! Map) return [];
      final map = Map<dynamic, dynamic>.from(snapshot.value as Map);
      final devices = map.entries
          .map((e) => LinkedDevice.fromMap(e.key as String, Map<dynamic, dynamic>.from(e.value as Map)))
          .toList()
        ..sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
      return devices;
    } catch (e) {
      debugPrint('UserDeviceRepository: fetchDevices failed: $e');
      return [];
    }
  }

  Future<void> unlinkDevice(String phoneKey, String deviceId) async {
    await _devicesRef(phoneKey).child(deviceId).remove();
  }
}
