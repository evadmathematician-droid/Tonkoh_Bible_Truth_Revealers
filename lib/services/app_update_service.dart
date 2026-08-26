import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Result of checking the app's build number against the minimum the
/// backend currently requires. `updateUrl` is always populated (falls back
/// to the Play Store listing for this package) so the force-update screen
/// always has somewhere to send the user.
class AppUpdateStatus {
  final bool updateRequired;
  final String updateUrl;

  /// True when this status came from Google Play's own in-app update check
  /// (PlayUpdateService) rather than the Firebase minBuildNumber fallback —
  /// tells ForceUpdateScreen to try Play's in-app immediate-update flow
  /// before falling back to opening the store listing.
  final bool usePlayImmediateFlow;

  const AppUpdateStatus({
    required this.updateRequired,
    required this.updateUrl,
    this.usePlayImmediateFlow = false,
  });
}

/// Gates app access on a minimum build number stored in Firebase, under
/// `appConfig/minBuildNumber`. Bump that value (and set `appConfig/updateUrl`
/// if it needs to point somewhere other than the Play Store listing) to force
/// every device below it into ForceUpdateScreen with no way to dismiss it —
/// this is deliberately NOT a "Later" style soft prompt.
///
/// If the check itself fails (offline, RTDB unreachable, etc.) we fail OPEN
/// — let the user into the app — rather than locking everyone out because of
/// a network hiccup. Once the device is back online, the next launch (or
/// resume) re-checks and will still enforce the gate correctly.
class AppUpdateService {
  static const defaultPlayStoreUrl =
      'https://play.google.com/store/apps/details?id=com.tbtrapp';

  static Future<AppUpdateStatus> check() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;

      final snap = await FirebaseDatabase.instance
          .ref('appConfig')
          .get()
          .timeout(const Duration(seconds: 8));

      if (!snap.exists) {
        return const AppUpdateStatus(updateRequired: false, updateUrl: defaultPlayStoreUrl);
      }

      final value = snap.value as Map<dynamic, dynamic>? ?? {};
      final minBuild = int.tryParse('${value['minBuildNumber'] ?? ''}') ?? 0;
      final configuredUrl = (value['updateUrl'] as String?)?.trim();
      final updateUrl = (configuredUrl != null && configuredUrl.isNotEmpty)
          ? configuredUrl
          : defaultPlayStoreUrl;

      return AppUpdateStatus(
        updateRequired: minBuild > 0 && currentBuild < minBuild,
        updateUrl: updateUrl,
      );
    } catch (e) {
      debugPrint('AppUpdateService: check failed, failing open: $e');
      return const AppUpdateStatus(updateRequired: false, updateUrl: defaultPlayStoreUrl);
    }
  }
}
