import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../services/play_update_service.dart';
import 'auth/auth_gate.dart';
import 'force_update_screen.dart';

/// Sits in front of AuthGate as the app's actual `home`. Runs the forced
/// update check before anything else can render, so an outdated build never
/// reaches sign-in, cached-profile restore, or any app content.
///
/// Two sources, checked in order:
///  1. Google Play's own in-app update API (PlayUpdateService) — Android +
///     Play Store only, matches what the previous native MainActivity used.
///  2. Firebase's appConfig/minBuildNumber (AppUpdateService) — cross-platform
///     fallback for iOS and any Android install Play can't cover (sideload,
///     other store).
class AppUpdateGate extends StatefulWidget {
  const AppUpdateGate({super.key});

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate> with WidgetsBindingObserver {
  AppUpdateStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Covers the user being sent out to the Play Store listing (or
    // updating externally) and returning without the OS fully restarting
    // the process — re-check so they're let in the moment they've actually
    // updated, instead of being stuck on ForceUpdateScreen until next cold
    // start.
    if (state == AppLifecycleState.resumed && _status?.updateRequired == true) {
      _check();
    }
  }

  Future<void> _check() async {
    if (!kIsWeb && Platform.isAndroid) {
      final playAvailable = await PlayUpdateService.immediateUpdateAvailable();
      if (playAvailable) {
        if (mounted) {
          setState(() => _status = const AppUpdateStatus(
                updateRequired: true,
                updateUrl: AppUpdateService.defaultPlayStoreUrl,
                usePlayImmediateFlow: true,
              ));
        }
        return;
      }
    }

    final status = await AppUpdateService.check();
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (status.updateRequired) {
      return ForceUpdateScreen(
        updateUrl: status.updateUrl,
        usePlayImmediateFlow: status.usePlayImmediateFlow,
      );
    }
    return const AuthGate();
  }
}
