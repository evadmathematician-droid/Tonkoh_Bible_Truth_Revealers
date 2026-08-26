import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../screens/auth/auth_manager.dart';
import '../util/phone_utils.dart';
import 'app_contact.dart';

/// Equivalent of ContactsRepository.kt.
///
/// ⚠️ GAP: Kotlin reads SIM contacts (content://icc/adn) and phone-account
/// contacts as two separate sources, tagging "SIM" vs "PHONE" so PHONE
/// wins on duplicates. No Flutter package exposes raw SIM-card contacts
/// distinctly — flutter_contacts reads the OS's unified Contacts Provider
/// (which on Android usually already has SIM contacts merged in by the OS,
/// just with no way to tell which ones came from there). So this reads one
/// list, tagged 'DEVICE' throughout. Keeping the same map/dedup shape
/// anyway so re-adding a real SIM-specific source later doesn't require
/// restructuring this.
///
/// ⚠️ WEB: flutter_contacts has no web implementation at all — device
/// contacts simply don't exist as a concept in a browser. Returns an
/// empty list on web rather than throwing, so this doesn't crash your
/// current web testing, but the Contacts screen will always show "no
/// matches" there. Worth deciding now whether you want a
/// "not supported on web" message in the UI step, since silently empty
/// could look like a bug otherwise.
class ContactsRepository {
  static Future<List<Map<String, String>>> readDeviceContacts() async {
    if (kIsWeb) return [];

    // flutter_contacts has its OWN internal permission check, separate
    // from permission_handler's (which ContactsSyncService already used
    // to gate whether to call this method at all). Logging both sides
    // here rather than assuming they agree — that's exactly the kind of
    // thing that silently breaks with an old plugin version on a newer
    // Android API level.
    final granted = await FlutterContacts.requestPermission();
    debugPrint('ContactsRepository: FlutterContacts.requestPermission() => $granted');
    if (!granted) return [];

    final results = <Map<String, String>>[];
    final contacts = await FlutterContacts.getContacts(withProperties: true);
    debugPrint('ContactsRepository: FlutterContacts.getContacts() returned ${contacts.length} raw contact(s)');
    for (final c in contacts) {
      final name = c.displayName;
      if (name.isEmpty) continue;
      for (final phone in c.phones) {
        if (phone.number.isEmpty) continue;
        results.add({'name': name, 'number': phone.number, 'source': 'DEVICE'});
      }
    }
    debugPrint('ContactsRepository: ${results.length} (name, number) pair(s) after filtering');
    return results;
  }

  static Future<List<AppContact>> fetchMatchedContacts() async {
    // Prefer the current user's OWN registered country over device-locale
    // guessing: normalizePhone() needs a region hint to interpret a locally
    // formatted number (no "+" prefix — the overwhelmingly common way real
    // address books store local contacts), and defaultRegion() can only
    // infer that from the device's OS locale (falling back to a hardcoded
    // "SL" when that parsing fails). Since a user's registered country is
    // exactly what every OTHER user's own phone number was normalized
    // against at signup, and the people in someone's address book are
    // overwhelmingly likely to share that same country, this is a far more
    // reliable primary hint — the previous device-locale-only approach
    // could silently fail to match real app users whenever the device's
    // locale didn't clearly reflect its actual country (e.g. a phone left
    // on a generic "English" locale with no region tag).
    final cachedProfile = await AuthManager.getCachedProfile();
    final region = (cachedProfile != null && cachedProfile.country.isNotEmpty)
        ? cachedProfile.country
        : defaultRegion();
    final deviceContacts = await readDeviceContacts();
    debugPrint(
      'ContactsRepository: region=$region, ${deviceContacts.length} device '
      'contact numbers read',
    );

    // Keyed by normalized E164 — later entries win on duplicate numbers,
    // same dedup behavior as the Kotlin map.
    final deviceByPhone = <String, ({String name, String source})>{};
    for (final entry in deviceContacts) {
      final normalized = normalizePhone(entry['number']!, region);
      if (normalized == null) continue;
      deviceByPhone[normalized] = (name: entry['name']!, source: entry['source']!);
    }

    try {
      final snapshot = await FirebaseDatabase.instance.ref('users').get();
      final matched = <AppContact>[];

      if (snapshot.exists && snapshot.value is Map) {
        (snapshot.value as Map).forEach((key, value) {
          if (value is! Map) return;
          final phone = value['phone'] as String?;
          if (phone == null) return;

          final entry = deviceByPhone[phone];
          debugPrint('ContactsRepository: users/$key phone=$phone matched=${entry != null}');
          if (entry != null) {
            matched.add(AppContact(
              name: entry.name,
              phone: phone,
              uid: value['uid'] as String?,
              photoUrl: value['photoUrl'] as String?,
              source: entry.source,
            ));
          }
        });
      }

      debugPrint('ContactsRepository: ${matched.length} matched contact(s)');
      matched.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return matched;
    } catch (e) {
      // Was a silent catch-all — any real failure (e.g. an RTDB permission
      // error reading the users node) looked identical to "no matches" with
      // nothing to debug from. Surface it instead of hiding it.
      debugPrint('ContactsRepository: fetchMatchedContacts failed: $e');
      return [];
    }
  }
}