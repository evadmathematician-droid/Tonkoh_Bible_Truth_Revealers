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
//
// This list is ONLY a matching aid: when a locally-typed contact number
// has no country code, it gets tried against each of these regions in
// turn so it still resolves to the correct E.164 form. It is NOT a
// default country for registration — that comes from the country picker
// (see ProfileSetupScreen) so users outside this list are fully supported.
const _fallbackRegions = ['SL', 'GN', 'LR', 'GH', 'NG'];

/// Real port of normalizePhone(raw, regionHint), replacing the earlier
/// naive stub that only existed to make AuthManager compile. Same
/// try-primary-then-fallback-list shape as the Kotlin version.
///
/// Uses `phone_numbers_parser` (pure Dart, works on web too — unlike a
/// native libphonenumber binding) as the closest equivalent to Google's
/// libphonenumber, which the Kotlin side calls directly.
///
/// FIX (Contacts screen only showing a handful of contacts): the Kotlin
/// original accepts a number when libphonenumber's `isValidNumber` is
/// true OR, failing that, when `isPossibleNumber` (length/structure only)
/// is true — because libphonenumber's per-country "valid" metadata is
/// incomplete and rejects many real, dialable mobile numbers (Sierra
/// Leone's numbering plan especially). The first Dart port dropped that
/// second chance and checked `isValid()` alone, so most device-contact
/// numbers failed to normalize, never entered the match map, and the
/// Contacts screen ended up intersecting an almost-empty set with
/// Firebase. `isValidLength()` is this package's length-only check — the
/// direct equivalent of `isPossibleNumber` — so it is restored here.
String? normalizePhone(String raw, String regionHint) {
  String? tryRegion(String region) {
    try {
      final iso = _isoForRegion(region);
      final phone = PhoneNumber.parse(raw, callerCountry: iso);
      if (phone.isValid() || phone.isValidLength()) {
        // `PhoneNumber.international` is already '+<countryCode><nsn>'
        // with no spaces — canonical E.164, matching what
        // AuthManager.saveProfile() writes to Firebase.
        return phone.international;
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

IsoCode _isoForRegion(String region) => IsoCode.values.firstWhere(
      (c) => c.name == region.toUpperCase(),
      orElse: () => IsoCode.US,
    );

/// Loose comparison key for two phone strings that *should* be the same
/// real number but were normalized on different devices / by different
/// app versions and might not be byte-identical (a stray leading zero, a
/// number stored under the wrong-but-close country code, an old record
/// saved before normalization existed).
///
/// Returns the last 9 significant digits. National subscriber numbers in
/// this app's user-base countries are 8–9 digits, so the last 9 digits
/// are stable across those formatting differences while still being long
/// enough not to collide between unrelated people.
String? loosePhoneKey(String? phone) {
  if (phone == null) return null;
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 7) return null;
  return digits.length <= 9 ? digits : digits.substring(digits.length - 9);
}
