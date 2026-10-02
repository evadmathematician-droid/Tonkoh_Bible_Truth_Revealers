import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Manufacturer-specific "keep calls working in the background" guidance.
///
/// Stock Android's battery-optimization exemption (asked once in
/// `PermissionsOnboarding`) is not enough on Transsion (Infinix/Tecno),
/// Xiaomi, Samsung, Oppo/Realme, Huawei etc. — they each have an extra
/// "Autostart" / "Protected apps" / "background activity" toggle that no app
/// can flip programmatically. Surface [tipForThisDevice] from a settings /
/// "calls not ringing?" screen and offer [openAppSettings] as the jump-off.
class CallReliabilityTips {
  CallReliabilityTips._();

  static Future<String> tipForThisDevice() async {
    if (kIsWeb) return '';
    String make = '';
    try {
      make = (await DeviceInfoPlugin().androidInfo).manufacturer.toLowerCase();
    } catch (_) {}

    if (make.contains('infinix') ||
        make.contains('tecno') ||
        make.contains('transsion') ||
        make.contains('itel')) {
      return 'On this phone, also turn on:\n'
          '• Settings → Apps → Tonkoh → Battery → allow "Auto launch" / '
          '"Background activity"\n'
          '• Phone Master / Power Marathon → Protected apps → add Tonkoh\n'
          'Otherwise calls and messages may not arrive while the app is closed.';
    }
    if (make.contains('xiaomi') || make.contains('redmi') || make.contains('poco')) {
      return 'On MIUI/HyperOS, also enable:\n'
          '• Settings → Apps → Tonkoh → Autostart\n'
          '• Battery saver → No restrictions\n'
          '• Lock the app in Recents (pull down on the app card)';
    }
    if (make.contains('samsung')) {
      return 'On Samsung, also:\n'
          '• Settings → Apps → Tonkoh → Battery → Unrestricted\n'
          '• Settings → Battery → Background usage limits → make sure Tonkoh '
          'is NOT in "Sleeping apps" / "Deep sleeping apps"';
    }
    if (make.contains('oppo') ||
        make.contains('realme') ||
        make.contains('oneplus') ||
        make.contains('vivo')) {
      return 'On ColorOS/OriginOS, also enable:\n'
          '• Settings → Apps → Tonkoh → Allow auto-launch\n'
          '• Battery → Allow background activity / disable "Sleep standby "'
          'optimization';
    }
    if (make.contains('huawei') || make.contains('honor')) {
      return 'On EMUI/MagicOS, also:\n'
          '• Settings → Apps → Tonkoh → Battery → App launch → Manage '
          'manually → turn on all three\n'
          '• Add Tonkoh to "Protected apps"';
    }
    return 'If calls or messages don\'t arrive while the app is closed, open '
        'Settings → Apps → Tonkoh → Battery and allow background/unrestricted '
        'activity.';
  }

  /// Opens the app's system settings page (the closest we can get to the
  /// OEM battery screens programmatically).
  static Future<void> openSettings() => openAppSettings();
}
