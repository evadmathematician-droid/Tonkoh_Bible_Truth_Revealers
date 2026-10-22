import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// The update policy an admin publishes in Firebase Remote Config.
///
/// Versions are compared as integer version codes (the `+N` build number in
/// pubspec.yaml / Android `versionCode`), never as version-name text.
@immutable
class ForceUpdatePolicy {
  const ForceUpdatePolicy({
    this.minVersionCode = 0,
    this.latestVersionCode = 0,
    this.forceUpdate = false,
    this.updateMessage = '',
    this.playStoreUrl = '',
    this.apkUrl = '',
    this.maintenanceMode = false,
    this.maintenanceMessage = '',
  });

  // Remote Config parameter names.
  static const String keyMinVersionCode = 'min_version_code';
  static const String keyLatestVersionCode = 'latest_version_code';
  static const String keyForceUpdate = 'force_update';
  static const String keyUpdateMessage = 'update_message';
  static const String keyPlayStoreUrl = 'playstore_url';
  static const String keyApkUrl = 'apk_url';
  static const String keyMaintenanceMode = 'maintenance_mode';
  static const String keyMaintenanceMessage = 'maintenance_message';

  static const List<String> allKeys = [
    keyMinVersionCode,
    keyLatestVersionCode,
    keyForceUpdate,
    keyUpdateMessage,
    keyPlayStoreUrl,
    keyApkUrl,
    keyMaintenanceMode,
    keyMaintenanceMessage,
  ];

  /// Values used before anything has ever been fetched: block nothing.
  static const Map<String, dynamic> defaults = {
    keyMinVersionCode: 0,
    keyLatestVersionCode: 0,
    keyForceUpdate: false,
    keyUpdateMessage: '',
    keyPlayStoreUrl: '',
    keyApkUrl: '',
    keyMaintenanceMode: false,
    keyMaintenanceMessage: '',
  };

  final int minVersionCode;
  final int latestVersionCode;
  final bool forceUpdate;
  final String updateMessage;
  final String playStoreUrl;
  final String apkUrl;
  final bool maintenanceMode;
  final String maintenanceMessage;

  factory ForceUpdatePolicy.fromRemoteConfig(FirebaseRemoteConfig rc) =>
      ForceUpdatePolicy(
        minVersionCode: rc.getInt(keyMinVersionCode),
        latestVersionCode: rc.getInt(keyLatestVersionCode),
        forceUpdate: rc.getBool(keyForceUpdate),
        updateMessage: rc.getString(keyUpdateMessage).trim(),
        playStoreUrl: rc.getString(keyPlayStoreUrl).trim(),
        apkUrl: rc.getString(keyApkUrl).trim(),
        maintenanceMode: rc.getBool(keyMaintenanceMode),
        maintenanceMessage: rc.getString(keyMaintenanceMessage).trim(),
      );

  static const String _prefsPrefix = 'force_update.';

  factory ForceUpdatePolicy.fromPrefs(SharedPreferences prefs) {
    String s(String k) => prefs.getString('$_prefsPrefix$k') ?? '';
    int i(String k) => prefs.getInt('$_prefsPrefix$k') ?? 0;
    bool b(String k) => prefs.getBool('$_prefsPrefix$k') ?? false;
    return ForceUpdatePolicy(
      minVersionCode: i(keyMinVersionCode),
      latestVersionCode: i(keyLatestVersionCode),
      forceUpdate: b(keyForceUpdate),
      updateMessage: s(keyUpdateMessage),
      playStoreUrl: s(keyPlayStoreUrl),
      apkUrl: s(keyApkUrl),
      maintenanceMode: b(keyMaintenanceMode),
      maintenanceMessage: s(keyMaintenanceMessage),
    );
  }

  Future<void> saveTo(SharedPreferences prefs) async {
    const p = _prefsPrefix;
    await prefs.setInt('$p$keyMinVersionCode', minVersionCode);
    await prefs.setInt('$p$keyLatestVersionCode', latestVersionCode);
    await prefs.setBool('$p$keyForceUpdate', forceUpdate);
    await prefs.setString('$p$keyUpdateMessage', updateMessage);
    await prefs.setString('$p$keyPlayStoreUrl', playStoreUrl);
    await prefs.setString('$p$keyApkUrl', apkUrl);
    await prefs.setBool('$p$keyMaintenanceMode', maintenanceMode);
    await prefs.setString('$p$keyMaintenanceMessage', maintenanceMessage);
  }

  /// Decides what [installedVersionCode] may do under this policy.
  ///
  /// Never blocks for a version update when:
  /// - `force_update` is false (the admin's off switch),
  /// - the installed version code is unknown (null),
  /// - `latest_version_code` is set but lower than `min_version_code` —
  ///   a misconfiguration that would lock everyone out with nothing newer
  ///   to install.
  ForceUpdateDecision evaluate(int? installedVersionCode) {
    if (maintenanceMode) return ForceUpdateDecision.maintenance;
    if (!forceUpdate || installedVersionCode == null) {
      return ForceUpdateDecision.allowed;
    }
    if (latestVersionCode > 0 && minVersionCode > latestVersionCode) {
      return ForceUpdateDecision.allowed;
    }
    return installedVersionCode < minVersionCode
        ? ForceUpdateDecision.updateRequired
        : ForceUpdateDecision.allowed;
  }
}

enum ForceUpdateDecision { allowed, updateRequired, maintenance }

/// The outcome of a check, published by [ForceUpdateManager.status].
@immutable
class ForceUpdateStatus {
  const ForceUpdateStatus({
    required this.decision,
    required this.policy,
    required this.installedVersionName,
    required this.installedVersionCode,
    this.playVersionCode,
  });

  final ForceUpdateDecision decision;
  final ForceUpdatePolicy policy;
  final String installedVersionName;
  final int? installedVersionCode;

  /// The newer version code Google Play offers this install, when Play's
  /// own check found one (Play installs only). Non-null blocks the app
  /// even if Remote Config doesn't.
  final int? playVersionCode;

  bool get isBlocked => decision != ForceUpdateDecision.allowed;
}

/// Decides whether the installed app may be used, and drives the update
/// flow when it may not.
///
/// The policy comes from Firebase Remote Config. Every successful fetch is
/// saved to shared_preferences, and that saved copy is enforced while the
/// device is offline — so an outdated install stays blocked offline, and a
/// version the last fetch confirmed as supported stays usable offline.
///
/// Independently of Remote Config, every check also asks Google Play
/// whether a newer build of this app is available (Play installs only).
/// If so the full-screen IMMEDIATE Play update starts at once, and the app
/// stays blocked behind [ForceUpdateScreen] until it is installed — so a
/// release reaches users as soon as Play rolls it out, with no console
/// change needed.
///
/// Admins change the policy only in the Firebase Console (or with
/// `tool/release.ps1`); the app holds no credentials that can change it.
///
/// Requires Firebase to be initialised before [check] is first called.
class ForceUpdateManager {
  ForceUpdateManager._();
  static final ForceUpdateManager instance = ForceUpdateManager._();

  static const String _playStoreInstaller = 'com.android.vending';

  static const String defaultUpdateMessage =
      'A new version of this app is required. Please update to continue.';
  static const String defaultMaintenanceMessage =
      'The app is undergoing maintenance. Please try again later.';

  /// How long a fetched policy is reused before Remote Config goes back to
  /// the network. Short, so a forced update published in the console blocks
  /// old versions at their next start / resume within minutes (open
  /// sessions get it at once through the real-time listener). Debug builds
  /// always fetch. Well within Remote Config's fetch quota.
  Duration minimumFetchInterval = const Duration(minutes: 5);

  /// Upper bound on how long a check waits for the network.
  Duration fetchTimeout = const Duration(seconds: 8);

  /// Null until the first check finishes.
  final ValueNotifier<ForceUpdateStatus?> status = ValueNotifier(null);

  bool get isBlocked => status.value?.isBlocked ?? false;

  PackageInfo? _packageInfo;
  ForceUpdatePolicy _policy = const ForceUpdatePolicy();
  Future<void>? _inFlight;
  bool _remoteConfigReady = false;
  StreamSubscription<RemoteConfigUpdate>? _realtimeSub;

  /// Version code Google Play offers (null: none / not a Play install).
  int? _playVersionCode;
  bool _playFlowRunning = false;
  DateTime? _playFlowEndedAt;

  /// Re-evaluates the installed version against the policy. Overlapping
  /// calls share a single check.
  Future<void> check() =>
      _inFlight ??= _check().whenComplete(() => _inFlight = null);

  Future<void> _check() async {
    // A web app always loads the latest deployed build; nothing to force.
    if (kIsWeb) {
      status.value = const ForceUpdateStatus(
        decision: ForceUpdateDecision.allowed,
        policy: ForceUpdatePolicy(),
        installedVersionName: '',
        installedVersionCode: null,
      );
      return;
    }

    _packageInfo ??= await PackageInfo.fromPlatform();
    final prefs = await SharedPreferences.getInstance();

    // First check of this launch: decide at once from the policy saved by
    // the last successful fetch, so the app opens immediately instead of
    // waiting up to [fetchTimeout] for the network behind a spinner. The
    // fetch below then confirms or updates the decision.
    if (status.value == null) {
      _publish(ForceUpdatePolicy.fromPrefs(prefs));
    }

    // Play's check runs alongside the Remote Config fetch; neither waits
    // for the other.
    final play = _checkPlay();
    final fresh = await _fetchRemote();
    if (fresh != null) {
      await fresh.saveTo(prefs);
      _policy = fresh;
    } else {
      _policy = ForceUpdatePolicy.fromPrefs(prefs);
    }
    _publish(_policy);
    await play;
  }

  void _publish(ForceUpdatePolicy policy) {
    _policy = policy;
    final code = int.tryParse(_packageInfo!.buildNumber);
    var decision = policy.evaluate(code);
    if (decision == ForceUpdateDecision.allowed && _playVersionCode != null) {
      decision = ForceUpdateDecision.updateRequired;
    }
    status.value = ForceUpdateStatus(
      decision: decision,
      policy: policy,
      installedVersionName: _packageInfo!.version,
      installedVersionCode: code,
      playVersionCode: _playVersionCode,
    );
  }

  bool get _installedFromPlay =>
      defaultTargetPlatform == TargetPlatform.android &&
      _packageInfo?.installerStore == _playStoreInstaller;

  /// Asks Google Play whether a newer build is available and, if so, blocks
  /// the app and starts the full-screen update. Never throws: Play's API
  /// fails on debug, sideloaded and emulator builds, which simply aren't
  /// blocked by this check.
  Future<void> _checkPlay() async {
    if (!_installedFromPlay || _playFlowRunning) return;
    AppUpdateInfo info;
    try {
      info = await InAppUpdate.checkForUpdate()
          .timeout(fetchTimeout + const Duration(seconds: 2));
    } catch (e) {
      debugPrint('ForceUpdateManager: Play update check skipped ($e)');
      return;
    }

    final inProgress = info.updateAvailability ==
        UpdateAvailability.developerTriggeredUpdateInProgress;
    final available =
        info.updateAvailability == UpdateAvailability.updateAvailable &&
            info.immediateUpdateAllowed;
    final installed = int.tryParse(_packageInfo!.buildNumber) ?? 0;
    final offered = info.availableVersionCode;
    final newer =
        inProgress || (available && (offered == null || offered > installed));

    final was = _playVersionCode;
    _playVersionCode = newer ? (offered ?? installed + 1) : null;
    if (was != _playVersionCode) _publish(_policy);
    if (!newer) return;

    // Backing out of Play's screen resumes the app, which runs another
    // check: don't throw the user straight back into Play. The blocking
    // screen's "Update Now" starts it again.
    final ended = _playFlowEndedAt;
    if (ended != null &&
        DateTime.now().difference(ended) < const Duration(seconds: 20)) {
      return;
    }
    await _runPlayImmediateUpdate(info);
  }

  /// Returns the server policy, or null when the device has no usable
  /// server values (offline, throttled, or never fetched).
  Future<ForceUpdatePolicy?> _fetchRemote() async {
    final rc = FirebaseRemoteConfig.instance;
    try {
      if (!_remoteConfigReady) {
        await rc.setConfigSettings(RemoteConfigSettings(
          fetchTimeout: fetchTimeout,
          minimumFetchInterval:
              kDebugMode ? Duration.zero : minimumFetchInterval,
        ));
        await rc.setDefaults(ForceUpdatePolicy.defaults);
        _remoteConfigReady = true;
        _listenForRealtimeUpdates(rc);
      }
      await rc
          .fetchAndActivate()
          .timeout(fetchTimeout + const Duration(seconds: 2));
    } catch (e) {
      // Offline / slow: keep using the saved policy; nothing to show.
      debugPrint('ForceUpdateManager: fetch skipped ($e)');
    }

    // `success` also covers a fetch skipped because the cached values are
    // still within minimumFetchInterval — those values are still valid.
    if (rc.lastFetchStatus != RemoteConfigFetchStatus.success) return null;
    return ForceUpdatePolicy.fromRemoteConfig(rc);
  }

  /// Picks up console changes while the app is open, so a newly published
  /// policy applies to running sessions straight away.
  void _listenForRealtimeUpdates(FirebaseRemoteConfig rc) {
    _realtimeSub ??= rc.onConfigUpdated.listen(
      (update) async {
        if (!update.updatedKeys.any(ForceUpdatePolicy.allKeys.contains)) {
          return;
        }
        await rc.activate();
        await check();
      },
      onError: (Object e) =>
          debugPrint('ForceUpdateManager: real-time updates unavailable: $e'),
    );
  }

  /// Starts the update. Returns false when nothing could be opened, so the
  /// caller can tell the user. Whether the update actually happened is
  /// decided by the next [check] (the gate runs one when the app resumes).
  Future<bool> startUpdate() async {
    _packageInfo ??= await PackageInfo.fromPlatform();
    final playUrl = _policy.playStoreUrl.isNotEmpty
        ? _policy.playStoreUrl
        : 'https://play.google.com/store/apps/details?id=${_packageInfo!.packageName}';
    final apkUrl = _policy.apkUrl;

    if (defaultTargetPlatform != TargetPlatform.android) {
      return _openUrl(playUrl);
    }

    if (_installedFromPlay) {
      if (await _runPlayImmediateUpdate()) return true;
      // Failed, cancelled or not offered by Play yet: send the user to the
      // store listing instead.
      return await _openUrl(playUrl) || await _openUrl(apkUrl);
    }
    // Sideloaded: the APK link first, the store listing as a fallback.
    return await _openUrl(apkUrl) || await _openUrl(playUrl);
  }

  /// Runs Google Play's full-screen IMMEDIATE in-app update. Returns true
  /// only if Play reports success (Play then restarts the app, so this
  /// rarely returns at all).
  Future<bool> _runPlayImmediateUpdate([AppUpdateInfo? known]) async {
    if (_playFlowRunning) return true;
    _playFlowRunning = true;
    try {
      final info = known ?? await InAppUpdate.checkForUpdate();
      final resumable = info.updateAvailability ==
          UpdateAvailability.developerTriggeredUpdateInProgress;
      final available =
          info.updateAvailability == UpdateAvailability.updateAvailable &&
              info.immediateUpdateAllowed;
      if (!resumable && !available) return false;

      final result = await InAppUpdate.performImmediateUpdate();
      return result == AppUpdateResult.success;
    } catch (e) {
      debugPrint('ForceUpdateManager: in-app update unavailable: $e');
      return false;
    } finally {
      _playFlowRunning = false;
      _playFlowEndedAt = DateTime.now();
    }
  }

  Future<bool> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('ForceUpdateManager: could not open $url: $e');
      return false;
    }
  }
}
