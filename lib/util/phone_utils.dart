import 'package:phone_numbers_parser/phone_numbers_parser.dart';

/// THE phone-number helper. Every place the app creates, saves, compares or
/// displays a phone number goes through this file (see docs/PHONE_AUDIT.md).
///
/// Accounts are keyed by the user's phone number in strict E.164 —
/// `+` + country code + national number, digits only (`+23231932652`).
/// Any other spelling of the same number must be turned into that exact
/// string before it touches Firebase or is compared with another number,
/// otherwise people can't find each other (the "Contacts shows only me"
/// bug) and chats split in two.
///
/// The parsing is `phone_numbers_parser` (pure Dart, built on Google's
/// libphonenumber metadata). tools/fix_phone_numbers.js mirrors these
/// rules with libphonenumber-js for the server-side data repair — keep the
/// two in step.

/// Sierra Leone — this app's home country and the default for numbers
/// typed without a country code, unless the user's own profile says
/// otherwise.
const String kDefaultCountry = 'SL';

/// Countries pinned to the top of the country picker, and tried in this
/// order when repairing a stored number whose country was guessed wrong.
const List<String> kPriorityCountries = ['SL', 'GN', 'LR', 'GH', 'NG'];

IsoCode? isoCodeFor(String country) {
  final up = country.trim().toUpperCase();
  for (final c in IsoCode.values) {
    if (c.name == up) return c;
  }
  return null;
}

/// Normalizes anything a person might type or a phone book might hold into
/// strict E.164, or returns null when it isn't a real number.
///
///  * `031932652`, `31932652`, `031 932 652`, `(031) 932652` → `+23231932652`
///    (no country code: read as a number of [defaultCountry]);
///  * `23231932652`, `+23231932652`, `0023231932652`, `+232 31 932 652`
///    → `+23231932652` (country code given, with or without `+`/`00`);
///  * `+031932652` — what an older app version saved by putting `+` in
///    front of a national number — → `+23231932652`;
///  * numbers of other countries keep their own country code
///    (`+44 7911 123456` → `+447911123456`);
///  * too short, too long, or not a valid number → null.
String? normalizePhone(String input, {String defaultCountry = kDefaultCountry}) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  final hasPlus = trimmed.startsWith('+') || trimmed.startsWith('＋');
  final digits = trimmed.replaceAll(RegExp(r'\D'), '');
  // E.164 allows at most 15 digits; "00" + 15 = 17. Below 6 nothing is a
  // dialable subscriber number anywhere.
  if (digits.length < 6 || digits.length > 17) return null;

  // International call prefix "00" (most of the world, including SL).
  if (digits.startsWith('00')) return _international(digits.substring(2));

  if (hasPlus) {
    // "+0…": a national number with a stray "+" in front of it.
    if (digits.startsWith('0')) return _national(digits, defaultCountry);
    return _international(digits);
  }

  final national = _national(digits, defaultCountry);
  if (national != null) return national;
  // Typed with the country code but without the "+", e.g. 23231932652.
  // Strict validity only, so a mistyped local number is never re-read as
  // some other country's number.
  return _international(digits, strict: true);
}

/// Repairs a phone number that is ALREADY stored (an account key, a
/// sender id, a feedback phone field). Same as [normalizePhone], plus one
/// extra case that only arises from stored data: an E.164 whose national
/// part still starts with the trunk `0` because the country was guessed
/// wrong at registration — `+44034909376` was really `034909376` typed in
/// Sierra Leone on a phone set to a UK locale. That number is re-read as a
/// national number of [defaultCountry], then of the other priority
/// countries, and the first strictly valid result wins.
String? repairStoredPhone(String stored,
    {String defaultCountry = kDefaultCountry}) {
  final direct = normalizePhone(stored, defaultCountry: defaultCountry);
  if (direct != null) return direct;

  final digits = stored.replaceAll(RegExp(r'\D'), '');
  if (!stored.trim().startsWith('+') || digits.length < 8) return null;
  try {
    final p = PhoneNumber.parse('+$digits');
    if (!p.nsn.startsWith('0')) return null;
    for (final country in {defaultCountry, ...kPriorityCountries}) {
      final iso = isoCodeFor(country);
      if (iso == null) continue;
      try {
        final q = PhoneNumber.parse(p.nsn, destinationCountry: iso);
        if (q.isValid()) return q.international;
      } catch (_) {}
    }
  } catch (_) {}
  return null;
}

String? _national(String digits, String country) {
  final iso = isoCodeFor(country) ?? IsoCode.SL;
  try {
    final p = PhoneNumber.parse(digits, destinationCountry: iso);
    if (p.isValid()) return p.international;
    // libphonenumber's metadata lags behind new number ranges, so in the
    // user's own country a number of the right length is accepted too —
    // unless it still starts with the trunk 0, which means the country is
    // wrong (that is exactly how "+44034909376" got saved).
    if (p.isoCode == iso && p.isValidLength() && !p.nsn.startsWith('0')) {
      return p.international;
    }
  } catch (_) {}
  return null;
}

String? _international(String digits, {bool strict = false}) {
  if (digits.isEmpty || digits.startsWith('0')) return null;
  PhoneNumber p;
  try {
    p = PhoneNumber.parse('+$digits');
  } catch (_) {
    return null;
  }
  if (p.isValid() ||
      (!strict && p.isValidLength() && !p.nsn.startsWith('0'))) {
    return p.international;
  }
  // "+232 076 123 456": the trunk 0 kept after the country code. Phone
  // books are full of these; drop it, as WhatsApp and the dialer do.
  if (p.nsn.startsWith('0')) {
    try {
      final q = PhoneNumber.parse('+${p.countryCode}${p.nsn.substring(1)}');
      if (q.isValid()) return q.international;
    } catch (_) {}
  }
  return null;
}

/// True if [value] is already exactly the strict E.164 form.
bool isE164(String value) =>
    value.startsWith('+') && normalizePhone(value) == value;

/// Account ids are phone numbers; a few very old records are keyed by an
/// anonymous-auth uid instead. Anything that looks like a phone number is
/// treated as one.
bool looksLikePhone(String value) =>
    RegExp(r'^\+?[\d\s\-().]{6,22}$').hasMatch(value.trim());

/// The canonical account id for [id]: a stored phone number repaired to
/// E.164 (`+031932652` → `+23231932652`), anything else unchanged. See
/// PhoneAliases.resolve, which also applies the server's alias table.
String canonicalUserId(String id) {
  final t = id.trim();
  if (!looksLikePhone(t)) return t;
  return _memo(_canonicalCache, t, () => repairStoredPhone(t) ?? t);
}

// Names and avatars resolve ids on every list row; parsing is cheap but
// not free, so both lookups are memoised (bounded — ids are few).
final Map<String, String> _canonicalCache = {};
final Map<String, String> _displayCache = {};

String _memo(Map<String, String> cache, String key, String Function() make) {
  final hit = cache[key];
  if (hit != null) return hit;
  if (cache.length > 4000) cache.clear();
  return cache[key] = make();
}

/// ISO country of an E.164 number ("SL" for +232…), or null.
String? countryOfPhone(String e164) {
  try {
    return PhoneNumber.parse(e164).isoCode.name;
  } catch (_) {
    return null;
  }
}

/// How a number is shown to people: `+23231932652` → `+232 31 932 652`.
/// Anything that isn't a phone number is returned unchanged; a stored
/// number in an old format is repaired first, so `+031932652` also shows as
/// `+232 31 932 652`.
String formatPhoneForDisplay(String value) {
  final raw = value.trim();
  if (!looksLikePhone(raw)) return raw;
  return _memo(_displayCache, raw, () => _formatForDisplay(raw));
}

String _formatForDisplay(String raw) {
  final e164 = repairStoredPhone(raw);
  if (e164 == null) return raw;
  try {
    final p = PhoneNumber.parse(e164);
    if (p.isoCode == IsoCode.SL && p.nsn.length == 8) {
      final n = p.nsn;
      return '+232 ${n.substring(0, 2)} ${n.substring(2, 5)} ${n.substring(5)}';
    }
    return '+${p.countryCode} ${p.formatNsn()}';
  } catch (_) {
    return e164;
  }
}

/// Loose comparison key for two phone strings that *should* be the same
/// real number but may not be byte-identical in legacy data. Returns the
/// last 9 significant digits. Only used to collapse duplicate chat rows —
/// never as an account id.
String? loosePhoneKey(String? phone) {
  if (phone == null) return null;
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 7) return null;
  return digits.length <= 9 ? digits : digits.substring(digits.length - 9);
}
