import 'dart:io' show Platform;

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import '../screens/auth/auth_manager.dart';
import '../util/phone_utils.dart' show kDefaultCountry;
import 'app_contact.dart';
import 'sim_contacts.dart';

/// The full device contact list, split WhatsApp/Telegram-style:
///  * [onApp]    — device contacts matched to a registered app user
///  * [notOnApp] — every other device contact (can only be invited)
class ContactBook {
  final List<AppContact> onApp;
  final List<AppContact> notOnApp;
  const ContactBook({this.onApp = const [], this.notOnApp = const []});
  int get total => onApp.length + notOnApp.length;
}

/// WhatsApp/Telegram-style contact discovery.
///
/// Reads the FULL device contact list (every source Android's
/// ContactsContract exposes — phone storage, synced Google/other accounts,
/// and SIM contacts the OS surfaces there), then classifies each contact as
/// "on the app" or "not on the app" by intersecting its numbers with the
/// app's entire `users` node in Firebase. No account-scoping at any stage.
///
/// ── Matching (unchanged from the earlier fix) ─────────────────────────
/// Per number: try EVERY candidate region and keep EVERY resulting E.164,
/// plus a country-code-agnostic key from the national subscriber number
/// (digits after the trunk `0` / after `+CC`). A contact is "on the app" if
/// any of its numbers shares an E.164 or NSN key with a registered user.
/// This is what makes a Sierra-Leone contact saved as `076123456` match the
/// registered user `+23276123456` even when the region guess was wrong
/// (`076123456` is a valid *length* for Ghana, so a single-region guess
/// used to mis-normalise it to `+233076123456` and match nothing).
class ContactsRepository {
  // ── DEBUG COUNTERS (surfaced on the Contacts screen) ──────────────────
  static int lastRawDeviceRows = 0; // device contacts read
  static int lastSimRows = 0; // SIM-card contacts merged in
  static int lastDeviceNumbers = 0; // total numbers across them
  static int lastKeyedNumbers = 0; // numbers that produced ≥1 match key
  static int lastFirebaseCount = 0;
  static int lastExactMatches = 0;
  static int lastLooseMatches = 0;
  static int lastNotOnApp = 0;
  static String lastRegions = '';
  static String lastError = '';
  // ─────────────────────────────────────────────────────────────────────

  static const List<String> _fallbackRegions = ['SL', 'GN', 'LR', 'GH', 'NG'];

  /// Every region a locally-typed number might belong to. Every one is
  /// tried and all results kept, so the order barely matters.
  static Future<List<String>> _candidateRegions() async {
    final out = <String>[];
    void add(String? r) {
      final u = (r ?? '').trim().toUpperCase();
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }

    add((await AuthManager.getCachedProfile())?.country);
    add(kDefaultCountry);
    for (final r in _fallbackRegions) {
      add(r);
    }
    return out;
  }

  static final Map<String, IsoCode?> _isoCache = {};
  static IsoCode? _iso(String region) => _isoCache.putIfAbsent(region, () {
        final up = region.toUpperCase();
        for (final c in IsoCode.values) {
          if (c.name == up) return c;
        }
        return null;
      });

  static String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');

  /// Match keys for one raw phone string:
  ///  * [e164s] — every distinct E.164 digit string across candidate regions
  ///  * [nsn]   — country-code-agnostic keys: last 9 / last 8 digits of the
  ///    national subscriber number (stable across `0`+NSN and `+CC`+NSN).
  static ({Set<String> e164s, Set<String> nsn}) phoneKeys(
      String raw, List<String> regions) {
    final e164s = <String>{};
    final nsn = <String>{};

    final rawDigits = _digits(raw);
    if (rawDigits.length < 6) return (e164s: e164s, nsn: nsn);

    void addNsnSuffixes(String n) {
      final d = _digits(n);
      if (d.length >= 9) nsn.add(d.substring(d.length - 9));
      if (d.length >= 8) {
        nsn.add(d.substring(d.length - 8));
      } else if (d.length >= 7) {
        nsn.add(d);
      }
    }

    for (final region in regions) {
      final iso = _iso(region);
      if (iso == null) continue;
      try {
        final p = PhoneNumber.parse(raw, callerCountry: iso);
        if (p.isValid() || p.isValidLength()) {
          e164s.add(_digits(p.international));
          addNsnSuffixes(p.nsn);
        }
      } catch (_) {
        // not parseable under this region — try the next
      }
    }

    if (e164s.isEmpty) {
      var bare = rawDigits;
      if (bare.startsWith('0') && bare.length > 7) bare = bare.substring(1);
      addNsnSuffixes(bare);
    }

    return (e164s: e164s, nsn: nsn);
  }

  /// The full device contact list, grouped by contact (one entry per
  /// person, all their numbers together). No account / SIM filter — this is
  /// the aggregated ContactsContract view across phone storage, Google /
  /// other synced accounts, and SIM contacts the OS exposes there.
  static Future<List<({String name, List<String> numbers})>>
      readDeviceContacts() async {
    if (kIsWeb || Platform.isWindows) return [];

    // readonly:true asks for READ_CONTACTS only — the default also requests
    // WRITE_CONTACTS, which this app never declares, so the plugin's
    // combined check could never pass.
    final granted = await FlutterContacts.requestPermission(readonly: true);
    debugPrint('[ContactsDebug] requestPermission(readonly:true) -> $granted');
    if (!granted) return [];

    var contacts = await FlutterContacts.getContacts(withProperties: true);
    if (contacts.isEmpty) {
      // provider occasionally not ready on the first call after a grant
      await Future<void>.delayed(const Duration(milliseconds: 400));
      contacts = await FlutterContacts.getContacts(withProperties: true);
    }
    debugPrint('[ContactsDebug] getContacts -> ${contacts.length} contacts');

    final out = <({String name, List<String> numbers})>[];
    final seenSuffix = <String>{}; // last-9-digit keys already covered

    String suffix9(String raw) {
      final d = _digits(raw);
      return d.length >= 9 ? d.substring(d.length - 9) : d;
    }

    for (final c in contacts) {
      final nums = <String>{};
      for (final p in c.phones) {
        final n = p.number.trim();
        if (n.isNotEmpty) {
          nums.add(n);
          seenSuffix.add(suffix9(n));
        }
      }
      if (nums.isEmpty) continue;
      final name = c.displayName.trim();
      out.add((name: name.isEmpty ? nums.first : name, numbers: nums.toList()));
    }

    // ── SIM-card contacts ────────────────────────────────────────────────
    // Not in ContactsContract, so flutter_contacts never returned them —
    // pulled from content://icc/adn (per-SIM on dual-SIM) via a native
    // channel. Merge them in as ordinary device contacts, skipping any
    // whose number already came through phone storage.
    lastSimRows = 0;
    try {
      final simContacts = await SimContacts.getAll();
      for (final s in simContacts) {
        final key = suffix9(s.number);
        if (key.length < 6 || !seenSuffix.add(key)) continue;
        lastSimRows++;
        out.add((
          name: s.name.isEmpty ? s.number : s.name,
          numbers: <String>[s.number],
        ));
      }
    } catch (e) {
      debugPrint('[ContactsDebug] SIM merge failed: $e');
    }

    return out;
  }

  /// Full device contact list, classified into app users vs. not.
  static Future<ContactBook> fetchContactBook() async {
    lastError = '';
    final regions = await _candidateRegions();
    lastRegions = regions.join(',');

    final deviceContacts = await readDeviceContacts();
    lastRawDeviceRows = deviceContacts.length;

    // ── Firebase user index: every key → user ──
    final fbIndex = <String, ({String uid, String phone, String? photo})>{};
    var firebaseCount = 0;
    try {
      final snap = await FirebaseDatabase.instance.ref('users').get();
      if (snap.exists && snap.value is Map) {
        (snap.value as Map).forEach((key, value) {
          if (value is! Map) return;
          firebaseCount++;
          final rawPhone = (value['phone'] as String?)?.trim();
          final phone = (rawPhone != null && rawPhone.isNotEmpty)
              ? rawPhone
              : key.toString();
          final user = (
            uid: (value['uid'] as String?) ?? key.toString(),
            phone: phone,
            photo: value['photoUrl'] as String?,
          );
          final cands = <String>{
            key.toString(),
            if (rawPhone != null && rawPhone.isNotEmpty) rawPhone,
          };
          for (final cand in cands) {
            final k = phoneKeys(cand, regions);
            for (final e in k.e164s) {
              fbIndex.putIfAbsent(e, () => user);
            }
            for (final n in k.nsn) {
              fbIndex.putIfAbsent('nsn:$n', () => user);
            }
            final d = _digits(cand);
            if (d.length >= 8) fbIndex.putIfAbsent(d, () => user);
          }
        });
      }
    } catch (e) {
      lastError = e.toString();
      debugPrint('[ContactsDebug] users fetch failed: $e');
      // fall through — with no index everyone lands in "not on app"
    }
    lastFirebaseCount = firebaseCount;

    // ── Classify each device contact ──
    final onApp = <AppContact>[];
    final notOnApp = <AppContact>[];
    final seenUid = <String>{};
    var numbers = 0, keyed = 0, exact = 0, loose = 0;

    for (final dc in deviceContacts) {
      ({String uid, String phone, String? photo})? hit;
      var hitLoose = false;

      for (final number in dc.numbers) {
        numbers++;
        final keys = phoneKeys(number, regions);
        if (keys.e164s.isNotEmpty || keys.nsn.isNotEmpty) keyed++;

        for (final e in keys.e164s) {
          final u = fbIndex[e];
          if (u != null) {
            hit = u;
            break;
          }
        }
        if (hit == null) {
          for (final n in keys.nsn) {
            final u = fbIndex['nsn:$n'];
            if (u != null) {
              hit = u;
              hitLoose = true;
              break;
            }
          }
        }
        if (hit != null) break;
      }

      if (hit != null) {
        if (seenUid.add(hit.uid)) {
          onApp.add(AppContact(
            name: dc.name,
            phone: hit.phone,
            uid: hit.uid,
            photoUrl: hit.photo,
            source: 'DEVICE',
          ));
          hitLoose ? loose++ : exact++;
        }
        // else: a second device contact for the same app user — drop it
      } else {
        notOnApp.add(AppContact(
          name: dc.name,
          phone: dc.numbers.first,
          source: 'DEVICE',
        ));
      }
    }

    int byName(AppContact a, AppContact b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    onApp.sort(byName);
    notOnApp.sort(byName);

    lastDeviceNumbers = numbers;
    lastKeyedNumbers = keyed;
    lastExactMatches = exact;
    lastLooseMatches = loose;
    lastNotOnApp = notOnApp.length;

    debugPrint('[ContactsDebug] regions=$lastRegions  device=${deviceContacts.length}  '
        'firebase=$firebaseCount  onApp=${onApp.length} '
        '(exact=$exact, loose=$loose)  notOnApp=${notOnApp.length}');

    return ContactBook(onApp: onApp, notOnApp: notOnApp);
  }
}
