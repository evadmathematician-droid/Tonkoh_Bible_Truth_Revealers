import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

/// Equivalent of defaultRegion(context) in PhoneUtils.kt.
///
/// ⚠️ GAP, flagging rather than silently downgrading: Android's version
/// reads the SIM's actual country (TelephonyManager.simCountryIso) first —
/// the most reliable signal, since it doesn't depend on device settings.
/// There's no cross-platform Flutter equivalent I can port faithfully
/// without an Android/iOS-only plugin (e.g. sim_data — not web-compatible,
/// less consistently maintained than I'd want to commit to sight-unseen).
/// This version goes straight to device locale as the primary signal,
/// which is weaker than SIM country (a misconfigured-locale device or
/// traveler gets it wrong where the Kotlin version wouldn't). Same
/// hardcoded "SL" bottom fallback either way.
String defaultRegion() {
  if (!kIsWeb) {
    try {
      final parts = Platform.localeName.split(RegExp('[_-]'));
      if (parts.length > 1 && parts[1].isNotEmpty) {
        return parts[1].toUpperCase();
      }
    } catch (_) {}
  }
  return 'SL';
}

// Same fallback list as FALLBACK_REGIONS in PhoneUtils.kt.
const _fallbackRegions = ['SL', 'GN', 'LR', 'GH', 'NG'];

/// Real port of normalizePhone(raw, regionHint), replacing the earlier
/// naive stub that only existed to make AuthManager compile. Same
/// try-primary-then-fallback-list shape as the Kotlin version.
///
/// Uses `phone_numbers_parser` (pure Dart, works on web too — unlike a
/// native libphonenumber binding) as the closest equivalent to Google's
/// libphonenumber, which the Kotlin side calls directly.
String? normalizePhone(String raw, String regionHint) {
  String? tryRegion(String region) {
    try {
      final iso = IsoCode.values.firstWhere(
            (c) => c.name == region,
        orElse: () => IsoCode.US,
      );
      final phone = PhoneNumber.parse(raw, callerCountry: iso);
      if (phone.isValid()) {
        return phone.international.replaceAll(RegExp(r'\s+'), '');
      }
    } catch (_) {}
    return null;
  }

  final primary = tryRegion(regionHint);
  if (primary != null) return primary;

  for (final region in _fallbackRegions) {
    if (region == regionHint) continue;
    final result = tryRegion(region);
    if (result != null) return result;
  }
  return null;
}