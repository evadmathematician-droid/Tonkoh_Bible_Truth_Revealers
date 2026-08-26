/// One entry under `users/{phone}/devices/{deviceId}` in Firebase Realtime
/// Database. deviceId is the device's OneSignal push-subscription id
/// (stable per install, already assigned for every device via the
/// existing OneSignal integration — see AuthManager.syncOneSignalPlayerId),
/// reused here instead of adding a new native device-identifier plugin.
class LinkedDevice {
  final String deviceId;
  final String platform; // 'android' | 'ios' | 'web'
  final int createdAt;
  final int lastActiveAt;

  const LinkedDevice({
    required this.deviceId,
    required this.platform,
    required this.createdAt,
    required this.lastActiveAt,
  });

  factory LinkedDevice.fromMap(String deviceId, Map<dynamic, dynamic> map) {
    return LinkedDevice(
      deviceId: deviceId,
      platform: map['platform'] as String? ?? 'unknown',
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
      lastActiveAt: (map['lastActiveAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'platform': platform,
        'createdAt': createdAt,
        'lastActiveAt': lastActiveAt,
      };
}
