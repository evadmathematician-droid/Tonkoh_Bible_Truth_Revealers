import 'package:flutter/material.dart';

import 'force_update_manager.dart';
import 'force_update_screen.dart';

/// Wraps the whole app and replaces it with [ForceUpdateScreen] while the
/// policy blocks this version (update required or maintenance mode).
///
/// Install it through `MaterialApp.builder` so it sits above the app's
/// Navigator — then no route, deep link or notification tap can reach a
/// screen while the app is blocked:
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) => ForceUpdateGate(
///     logo: Image.asset('assets/icon/icon.png'),
///     child: child!,
///   ),
///   ...
/// )
/// ```
class ForceUpdateGate extends StatefulWidget {
  const ForceUpdateGate({super.key, required this.logo, required this.child});

  /// Shown on the blocking screen and while the first check runs.
  final Widget logo;
  final Widget child;

  @override
  State<ForceUpdateGate> createState() => _ForceUpdateGateState();
}

class _ForceUpdateGateState extends State<ForceUpdateGate>
    with WidgetsBindingObserver {
  final _manager = ForceUpdateManager.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _manager.check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Covers both an old session brought back from the background and the
    // user returning from the store or the APK installer.
    if (state == AppLifecycleState.resumed) _manager.check();
  }

  /// While blocked, the app's own Navigator is not in the tree, so the
  /// system back button would otherwise close the app instead of doing
  /// nothing. Swallow it.
  @override
  Future<bool> didPopRoute() async => _manager.isBlocked;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ForceUpdateStatus?>(
      valueListenable: _manager.status,
      builder: (context, status, _) {
        if (status == null) return _CheckingScreen(logo: widget.logo);
        if (!status.isBlocked) return widget.child;

        // A dedicated Navigator gives the screen a route, which PopScope
        // needs in order to block back (including predictive back).
        return Navigator(
          pages: [
            MaterialPage(
              key: const ValueKey('force-update'),
              child: ForceUpdateScreen(status: status, logo: widget.logo),
            ),
          ],
          onDidRemovePage: (_) {},
        );
      },
    );
  }
}

/// Shown once at launch, until the first check finishes.
class _CheckingScreen extends StatelessWidget {
  const _CheckingScreen({required this.logo});

  final Widget logo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 96, height: 96, child: logo),
            const SizedBox(height: 32),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}
