import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../navigation/call_navigator.dart';

/// The app's permission asks: the standard Android "Allow / Don't allow"
/// popups one after another, skipping whatever is already allowed. A
/// "Don't allow" just moves on — nothing here ever blocks the app.
///
/// Runs right after registration (before home), once for existing users
/// ([maybeRunOnce], after home appears) and from Settings → App permissions.
class PermissionFlow {
  PermissionFlow._();

  static const MethodChannel _native = MethodChannel('com.tbtrapp/ring_setup');
  static const String _askedKey = 'permissionsAsked_v1';

  /// Popups with a system dialog, in order. Phone (READ_PHONE_STATE) is for
  /// call routing and SIM contacts; contacts feed contact sync.
  static const _permissions = <Permission>[
    Permission.notification,
    Permission.microphone,
    Permission.phone,
    Permission.camera,
    Permission.contacts,
    Permission.ignoreBatteryOptimizations,
  ];

  /// Phones that stop closed apps unless "Auto-start" / background activity
  /// is allowed for them (Infinix / Tecno / itel, Xiaomi, Oppo, Vivo,
  /// Huawei and their sub-brands). Matched against Build.MANUFACTURER.
  static const _autoStartMakers = [
    'infinix', 'tecno', 'itel', 'transsion',
    'xiaomi', 'redmi', 'poco',
    'oppo', 'realme',
    'vivo', 'iqoo',
    'huawei', 'honor',
  ];

  static Future<void>? _running;
  static bool _ranThisSession = false;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Completes once no sequence is on screen — other permission requests
  /// wait for it (two requests at once fail).
  static Future<void> get idle => _running ?? Future<void>.value();

  /// Whether this phone has been through the sequence.
  static Future<bool> hasAsked() async =>
      (await SharedPreferences.getInstance()).getBool(_askedKey) == true;

  /// Existing users who never saw the sequence: run it once.
  static Future<void> maybeRunOnce(BuildContext context) async {
    if (!supported || _ranThisSession || _running != null) return;
    if (await hasAsked() || !context.mounted) return;
    await requestAll(context);
  }

  /// Runs the whole sequence; completes when it is done, whatever the
  /// answers. Never starts during a call.
  static Future<void> requestAll(BuildContext context) {
    if (!supported || CallNavigator.inCall) return Future<void>.value();
    return _running ??= _run(context).whenComplete(() => _running = null);
  }

  static Future<void> _run(BuildContext context) async {
    _ranThisSession = true;
    // Saved first: being killed halfway must not bring it back every launch.
    await (await SharedPreferences.getInstance()).setBool(_askedKey, true);

    for (final permission in _permissions) {
      if (CallNavigator.inCall) return;
      try {
        if (!await permission.isGranted) await permission.request();
      } catch (e) {
        debugPrint('PermissionFlow: $permission failed: $e');
      }
    }

    if (CallNavigator.inCall || !context.mounted) return;
    await _fullScreenCalls(context);
    if (CallNavigator.inCall || !context.mounted) return;
    await _autoStart(context);
  }

  /// Android 14+ can switch off full-screen ringing for an app; there is no
  /// system popup for it, only a settings page.
  static Future<void> _fullScreenCalls(BuildContext context) async {
    bool allowed = true;
    try {
      allowed =
          await _native.invokeMethod<bool>('canUseFullScreenIntent') ?? true;
    } catch (_) {}
    if (allowed || !context.mounted) return;
    if (await _ask(context, 'Allow incoming calls on lock screen?')) {
      try {
        await _native.invokeMethod('openFullScreenIntentSettings');
      } catch (_) {}
    }
  }

  static Future<void> _autoStart(BuildContext context) async {
    String make = '';
    try {
      make = (await _native.invokeMethod<String>('manufacturer') ?? '')
          .toLowerCase();
    } catch (_) {}
    if (!_autoStartMakers.any(make.contains) || !context.mounted) return;
    if (await _ask(context, 'Allow TBTR to run in background?',
        message: 'So calls and messages arrive when the app is closed.')) {
      try {
        // Falls back to the app's settings page on an unknown model.
        await _native.invokeMethod('openAutoStartSettings');
      } catch (_) {}
    }
  }

  /// A plain white two-button dialog in the system popups' style.
  static Future<bool> _ask(BuildContext context, String title,
      {String? message}) async {
    final allow = await showDialog<bool>(
      context: context,
      builder: (ctx) => Theme(
        data: ThemeData(
          useMaterial3: true,
          colorScheme: const ColorScheme.light(primary: Color(0xFF102A72)),
        ),
        child: AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          title: Text(title),
          content: message == null ? null : Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Don't allow"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Allow'),
            ),
          ],
        ),
      ),
    );
    return allow == true;
  }
}
