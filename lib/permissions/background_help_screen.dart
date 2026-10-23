import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tecno / Infinix / itel and Xiaomi phones stop closed apps, so calls and
/// messages only arrive once TBTR is opened. Shown once after sign-in (see
/// [PermissionFlow]) on those phones only: explains why, and offers the
/// two switches that fix it. Never shown again once done or skipped.
class BackgroundHelpScreen extends StatefulWidget {
  const BackgroundHelpScreen({super.key, required this.brand});

  /// "Infinix", "Xiaomi", … — for the text.
  final String brand;

  static const MethodChannel _native = MethodChannel('com.tbtrapp/ring_setup');
  static const String _shownKey = 'backgroundHelpShown_v1';

  static const _makers = {
    'infinix': 'Infinix',
    'tecno': 'Tecno',
    'itel': 'itel',
    'transsion': 'Tecno',
    'xiaomi': 'Xiaomi',
    'redmi': 'Redmi',
    'poco': 'POCO',
  };

  /// The phone's brand when it is one this screen is for, else null.
  static Future<String?> brandNeedingHelp() async {
    String make = '';
    try {
      make = (await _native.invokeMethod<String>('manufacturer') ?? '')
          .toLowerCase();
    } catch (_) {}
    for (final e in _makers.entries) {
      if (make.contains(e.key)) return e.value;
    }
    return null;
  }

  static Future<bool> wasShown() async =>
      (await SharedPreferences.getInstance()).getBool(_shownKey) == true;

  /// Shows the screen for [brand] unless it was shown before.
  static Future<void> maybeShowOnce(BuildContext context, String brand) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_shownKey) == true || !context.mounted) return;
    // Saved first: it must never come back, even if the app is killed on it.
    await prefs.setBool(_shownKey, true);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => BackgroundHelpScreen(brand: brand),
    ));
  }

  @override
  State<BackgroundHelpScreen> createState() => _BackgroundHelpScreenState();
}

class _BackgroundHelpScreenState extends State<BackgroundHelpScreen> {
  static const _accent = Color(0xFF102A72);

  bool _batteryAllowed = false;
  bool _autoStartOpened = false;

  @override
  void initState() {
    super.initState();
    Permission.ignoreBatteryOptimizations.isGranted.then((v) {
      if (mounted && v) setState(() => _batteryAllowed = true);
    });
  }

  Future<void> _allowBattery() async {
    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {}
    final granted = await Permission.ignoreBatteryOptimizations.isGranted;
    if (mounted) setState(() => _batteryAllowed = granted);
  }

  Future<void> _openAutoStart() async {
    try {
      // Falls back to the app's settings page on an unknown model.
      await BackgroundHelpScreen._native.invokeMethod('openAutoStartSettings');
    } catch (_) {}
    if (mounted) setState(() => _autoStartOpened = true);
  }

  @override
  Widget build(BuildContext context) {
    final done = _batteryAllowed && _autoStartOpened;
    return Scaffold(
      appBar: AppBar(
        foregroundColor: _accent,
        title: const Text('Get calls when TBTR is closed'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Text(
              '${widget.brand} phones stop apps that are closed. Then TBTR '
              'calls and messages only arrive when you open the app.',
              style: const TextStyle(fontSize: 16, height: 1.4),
            ),
            const SizedBox(height: 12),
            const Text(
              'Allow TBTR to run in the background, so your phone rings for '
              'calls and shows messages at once — like WhatsApp.',
              style: TextStyle(fontSize: 16, height: 1.4),
            ),
            const SizedBox(height: 24),
            _StepButton(
              number: 1,
              label: 'Allow background use',
              hint: 'Choose "Allow" in the popup.',
              done: _batteryAllowed,
              onPressed: _allowBattery,
            ),
            const SizedBox(height: 12),
            _StepButton(
              number: 2,
              label: 'Turn on auto-start',
              hint: 'Find TBTR and switch on "Auto-start" (or "Auto launch"), '
                  'then come back.',
              done: _autoStartOpened,
              onPressed: _openAutoStart,
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: 50,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(done ? 'Done' : 'Skip',
                    style: const TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.number,
    required this.label,
    required this.hint,
    required this.done,
    required this.onPressed,
  });

  final int number;
  final String label;
  final String hint;
  final bool done;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 50,
          child: OutlinedButton.icon(
            onPressed: onPressed,
            icon: done
                ? const Icon(Icons.check_circle, color: Colors.green)
                : CircleAvatar(
                    radius: 11,
                    backgroundColor: const Color(0xFF102A72),
                    child: Text('$number',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white)),
                  ),
            label: Text(label, style: const TextStyle(fontSize: 16)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: Text(hint,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
        ),
      ],
    );
  }
}
