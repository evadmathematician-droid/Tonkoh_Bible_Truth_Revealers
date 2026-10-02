import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// The outcome of a version check, published by [ForceUpdateService.status].
@immutable
class ForceUpdateStatus {
  const ForceUpdateStatus({
    required this.mustUpdate,
    required this.currentVersion,
    required this.requiredVersion,
    required this.message,
  });

  /// True when the installed version is below the minimum required version.
  final bool mustUpdate;
  final String currentVersion;
  final String requiredVersion;
  final String message;
}

/// Decides whether the installed app is too old to be used, and drives the
/// update flow when it is.
///
/// The minimum version comes from Firebase Remote Config. Every successful
/// fetch is also saved to shared_preferences, so a device that goes offline
/// stays blocked against the last known minimum instead of slipping through.
///
/// Requires Firebase to be initialised before [check] is first called.
class ForceUpdateService {
  ForceUpdateService._();
  static final ForceUpdateService instance = ForceUpdateService._();

  // Remote Config parameter names.
  static const String keyMinVersion = 'min_required_version';
  static const String keyPlayStoreUrl = 'update_url_playstore';
  static const String keyApkUrl = 'update_url_apk';
  static const String keyAppStoreUrl = 'update_url_appstore'; // optional, iOS
  static const String keyMessage = 'update_message';

  static const List<String> _remoteKeys = [
    keyMinVersion,
    keyPlayStoreUrl,
    keyApkUrl,
    keyAppStoreUrl,
    keyMessage,
  ];

  static const String _prefsPrefix = 'force_update.';
  static const String _playStoreInstaller = 'com.android.vending';

  static const String defaultMessage =
      'A new version of this app is available. Please update to continue.';

  /// How long a fetched config is reused before Remote Config goes back to
  /// the network. Debug builds always fetch. Changes published in the
  /// console still arrive immediately through the real-time listener.
  Duration minimumFetchInterval = const Duration(hours: 1);

  /// Upper bound on how long a check waits for the network.
  Duration fetchTimeout = const Duration(seconds: 8);

  /// Null until the first check finishes.
  final ValueNotifier<ForceUpdateStatus?> status = ValueNotifier(null);

  bool get isBlocked => status.value?.mustUpdate ?? false;

  PackageInfo? _packageInfo;
  Map<String, String> _config = const {};
  Future<void>? _inFlight;
  bool _remoteConfigReady = false;
  StreamSubscription<RemoteConfigUpdate>? _realtimeSub;

  /// Re-evaluates the installed version against the minimum required one.
  /// Overlapping calls share a single check.
  Future<void> check() =>
      _inFlight ??= _check().whenComplete(() => _inFlight = null);

  Future<void> _check() async {
    // A web app always loads the latest deployed build, so there is never
    // anything to force.
    if (kIsWeb) {
      status.value = const ForceUpdateStatus(
        mustUpdate: false,
        currentVersion: '',
        requiredVersion: '',
        message: '',
      );
      return;
    }

    _packageInfo ??= await PackageInfo.fromPlatform();
    final prefs = await SharedPreferences.getInstance();

    final fresh = await _fetchRemote();
    if (fresh != null) {
      await _writeCache(prefs, fresh);
      _config = fresh;
    } else {
      _config = _readCache(prefs);
    }

    final current = _packageInfo!.version;
    final required = _config[keyMinVersion] ?? '';
    final message = _config[keyMessage] ?? '';
    status.value = ForceUpdateStatus(
      // An empty or malformed minimum never blocks — a typo in the console
      // must not lock every user out.
      mustUpdate: (compareVersions(current, required) ?? 0) < 0,
      currentVersion: current,
      requiredVersion: required,
      message: message.isEmpty ? defaultMessage : message,
    );
  }

  /// Returns the server values, or null when the device has no usable
  /// server values (offline, throttled, or never fetched).
  Future<Map<String, String>?> _fetchRemote() async {
    final rc = FirebaseRemoteConfig.instance;
    try {
      if (!_remoteConfigReady) {
        await rc.setConfigSettings(RemoteConfigSettings(
          fetchTimeout: fetchTimeout,
          minimumFetchInterval:
              kDebugMode ? Duration.zero : minimumFetchInterval,
        ));
        await rc.setDefaults({for (final k in _remoteKeys) k: ''});
        _remoteConfigReady = true;
        _listenForRealtimeUpdates(rc);
      }
      await rc
          .fetchAndActivate()
          .timeout(fetchTimeout + const Duration(seconds: 2));
    } catch (e) {
      debugPrint('ForceUpdateService: fetch failed: $e');
    }

    // `success` also covers a fetch skipped because the cached values are
    // still within minimumFetchInterval — those values are still valid.
    if (rc.lastFetchStatus != RemoteConfigFetchStatus.success) return null;
    return {for (final k in _remoteKeys) k: rc.getString(k).trim()};
  }

  /// Picks up console changes while the app is open, so raising the minimum
  /// version blocks running sessions straight away.
  void _listenForRealtimeUpdates(FirebaseRemoteConfig rc) {
    _realtimeSub ??= rc.onConfigUpdated.listen(
      (update) async {
        if (!update.updatedKeys.any(_remoteKeys.contains)) return;
        await rc.activate();
        await check();
      },
      onError: (Object e) =>
          debugPrint('ForceUpdateService: real-time updates unavailable: $e'),
    );
  }

  Map<String, String> _readCache(SharedPreferences prefs) => {
        for (final k in _remoteKeys) k: prefs.getString('$_prefsPrefix$k') ?? '',
      };

  Future<void> _writeCache(
      SharedPreferences prefs, Map<String, String> values) async {
    for (final e in values.entries) {
      await prefs.setString('$_prefsPrefix${e.key}', e.value);
    }
  }

  /// Starts the update. Returns false when nothing could be opened, so the
  /// caller can tell the user. Whether the update actually happened is
  /// decided by the next [check] (the gate runs one when the app resumes).
  Future<bool> startUpdate() async {
    _packageInfo ??= await PackageInfo.fromPlatform();

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return _openUrl(_config[keyAppStoreUrl] ?? '');
    }

    final fromPlay = _packageInfo!.installerStore == _playStoreInstaller;
    if (fromPlay && await _tryPlayImmediateUpdate()) {
      await check();
      return true;
    }

    final playUrl = _config[keyPlayStoreUrl] ?? '';
    final apkUrl = _config[keyApkUrl] ?? '';
    if (fromPlay) return _openUrl(playUrl);
    // Sideloaded: the APK link first, the store page as a fallback.
    return await _openUrl(apkUrl) || await _openUrl(playUrl);
  }

  /// Runs Google Play's full-screen in-app update. Returns false when Play
  /// cannot run it (no update visible to Play yet, API error), so the caller
  /// falls back to opening a link.
  Future<bool> _tryPlayImmediateUpdate() async {
    try {
      final info = await InAppUpdate.checkForUpdate();
      final resumable = info.updateAvailability ==
          UpdateAvailability.developerTriggeredUpdateInProgress;
      final available =
          info.updateAvailability == UpdateAvailability.updateAvailable &&
              info.immediateUpdateAllowed;
      if (!resumable && !available) return false;

      // On success Play installs the update and restarts the app, so this
      // usually does not return. A cancelled update leaves the user on the
      // blocking screen.
      final result = await InAppUpdate.performImmediateUpdate();
      return result != AppUpdateResult.inAppUpdateFailed;
    } catch (e) {
      debugPrint('ForceUpdateService: in-app update unavailable: $e');
      return false;
    }
  }

  Future<bool> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('ForceUpdateService: could not open $url: $e');
      return false;
    }
  }

  /// Compares two `major.minor.patch` versions numerically, so 1.10.0 is
  /// newer than 1.9.0. Missing parts count as 0 ("1.4" == "1.4.0"); a
  /// leading "v" and any "+build" or "-pre" suffix are ignored.
  ///
  /// Returns a negative number if [a] is older, 0 if equal, positive if
  /// newer, or null if either is not a valid version.
  static int? compareVersions(String a, String b) {
    final pa = _parseVersion(a);
    final pb = _parseVersion(b);
    if (pa == null || pb == null) return null;
    for (var i = 0; i < 3; i++) {
      final d = pa[i].compareTo(pb[i]);
      if (d != 0) return d;
    }
    return 0;
  }

  static List<int>? _parseVersion(String version) {
    var core = version.trim().split(RegExp(r'[+-]')).first;
    if (core.startsWith('v') || core.startsWith('V')) core = core.substring(1);
    if (core.isEmpty) return null;

    final parts = core.split('.');
    if (parts.length > 3) return null;
    final numbers = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0) return null;
      numbers.add(n);
    }
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return numbers;
  }
}
