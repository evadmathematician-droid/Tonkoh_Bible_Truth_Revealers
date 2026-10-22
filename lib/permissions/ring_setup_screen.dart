import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../navigation/call_navigator.dart';

/// "Allow TBTR to ring when closed": the phone settings that decide whether
/// calls ring and messages arrive while the app is closed or the screen is
/// locked. Each row turns green once allowed.
///
/// Shown once after sign-in ([maybeShowOnce]) — existing users included,
/// since the old permission prompts only ran right after registration —
/// and from Settings → "Ring when app is closed".
class RingSetupScreen extends StatefulWidget {
  const RingSetupScreen({super.key});

  static const MethodChannel _native = MethodChannel('com.tbtrapp/ring_setup');
  static const String _shownKey = 'ring_setup_shown_v1';
  static bool _showing = false;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Shows the screen if it has never been shown on this phone.
  static Future<void> maybeShowOnce() async {
    if (!supported || _showing) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_shownKey) == true) return;
    final nav = CallNavigator.key.currentState;
    if (nav == null) return;
    _showing = true;
    await prefs.setBool(_shownKey, true);
    try {
      await nav.push(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const RingSetupScreen(),
      ));
    } finally {
      _showing = false;
    }
  }

  @override
  State<RingSetupScreen> createState() => _RingSetupScreenState();
}

class _RingSetupScreenState extends State<RingSetupScreen>
    with WidgetsBindingObserver {
  static const _accent = Color(0xFF102A72);
  static const _native = RingSetupScreen._native;

  bool _notifications = false;
  bool _fullScreen = false;
  bool _battery = false;
  bool _autoStartOpened = false;
  bool _transsion = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from a system settings page: show what changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    bool fullScreen = true;
    String make = '';
    try {
      fullScreen =
          await _native.invokeMethod<bool>('canUseFullScreenIntent') ?? true;
      make = (await _native.invokeMethod<String>('manufacturer') ?? '')
          .toLowerCase();
    } catch (_) {}
    final notifications = await Permission.notification.isGranted;
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!mounted) return;
    setState(() {
      _notifications = notifications;
      _fullScreen = fullScreen;
      _battery = battery;
      _transsion = const ['infinix', 'tecno', 'itel', 'transsion']
          .any(make.contains);
    });
  }

  Future<void> _askNotifications() async {
    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied) await openAppSettings();
    await _refresh();
  }

  Future<void> _askBattery() async {
    await Permission.ignoreBatteryOptimizations.request();
    await _refresh();
  }

  Future<void> _openFullScreen() async {
    try {
      await _native.invokeMethod('openFullScreenIntentSettings');
    } catch (_) {}
  }

  Future<void> _openAutoStart() async {
    bool found = false;
    try {
      found = await _native.invokeMethod<bool>('openAutoStartSettings') ?? false;
    } catch (_) {}
    if (!mounted) return;
    setState(() => _autoStartOpened = true);
    if (!found) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Look for "Auto-start", "Auto launch" or "Background '
            'activity" on this page and allow it for TBTR.'),
        duration: Duration(seconds: 6),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        foregroundColor: _accent,
        title: const Text('Ring when closed'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            const Icon(Icons.ring_volume, size: 56, color: _accent),
            const SizedBox(height: 12),
            const Text(
              'Allow TBTR to ring when closed',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'So calls ring and messages arrive even when the app is closed '
              'or the screen is locked. Tap each step and allow it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 20),
            _Step(
              done: _notifications,
              icon: Icons.notifications_active_outlined,
              title: 'Show notifications',
              subtitle: 'Needed for messages and the ringing screen.',
              onTap: _askNotifications,
            ),
            _Step(
              done: _fullScreen,
              icon: Icons.fullscreen,
              title: 'Full-screen calls',
              subtitle: 'Lets an incoming call fill the screen, even when '
                  'it is locked.',
              onTap: _openFullScreen,
            ),
            _Step(
              done: _battery,
              icon: Icons.battery_charging_full,
              title: 'No battery limits',
              subtitle: "Stops the phone from putting TBTR to sleep. Choose "
                  '"Allow".',
              onTap: _askBattery,
            ),
            _Step(
              done: _autoStartOpened,
              icon: Icons.rocket_launch_outlined,
              title: _transsion
                  ? 'Auto-start (Infinix / Tecno / itel)'
                  : 'Auto-start / background activity',
              subtitle: _transsion
                  ? 'In Phone Master, turn on Auto-start for TBTR. Without it '
                      'this phone stops closed apps from ringing.'
                  : 'If your phone has an Auto-start or "background activity" '
                      'switch, turn it on for TBTR.',
              onTap: _openAutoStart,
              doneLabel: 'Opened',
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'You can open this again from Settings → Ring when app is closed.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.done,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.doneLabel = 'Allowed',
  });

  final bool done;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String doneLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon, color: done ? Colors.green : const Color(0xFF102A72)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: done
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 20),
                const SizedBox(width: 4),
                Text(doneLabel,
                    style: const TextStyle(color: Colors.green, fontSize: 12)),
              ])
            : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
