import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_contacts/flutter_contacts.dart';

import '../screens/auth/auth_manager.dart';
import '../util/phone_utils.dart';
import 'app_contact.dart';
import 'phone_aliases.dart';
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

/// Counters from the last sync, shown on the hidden diagnostics line of
/// the Contacts screen (long-press its title).
class ContactSyncStats {
  final int contactsRead; // device + SIM contacts with at least one number
  final int numbersRead; // every number of every contact
  final int validNumbers; // distinct numbers that normalized to E.164
  final int onApp;
  final int failedLookups; // lookups that errored (offline, timeout)
  final DateTime? lastSync;

  const ContactSyncStats({
    this.contactsRead = 0,
    this.numbersRead = 0,
    this.validNumbers = 0,
    this.onApp = 0,
    this.failedLookups = 0,
    this.lastSync,
  });

  Map<String, Object?> toJson() => {
        'contactsRead': contactsRead,
        'numbersRead': numbersRead,
        'validNumbers': validNumbers,
        'onApp': onApp,
        'failedLookups': failedLookups,
        'lastSync': lastSync?.millisecondsSinceEpoch,
      };

  factory ContactSyncStats.fromJson(Map<dynamic, dynamic> j) =>
      ContactSyncStats(
        contactsRead: (j['contactsRead'] as num?)?.toInt() ?? 0,
        numbersRead: (j['numbersRead'] as num?)?.toInt() ?? 0,
        validNumbers: (j['validNumbers'] as num?)?.toInt() ?? 0,
        onApp: (j['onApp'] as num?)?.toInt() ?? 0,
        failedLookups: (j['failedLookups'] as num?)?.toInt() ?? 0,
        lastSync: j['lastSync'] is num
            ? DateTime.fromMillisecondsSinceEpoch((j['lastSync'] as num).toInt())
            : null,
      );
}

typedef DeviceContact = ({String name, List<String> numbers});

/// Result of looking one E.164 number up: registered or not, or the lookup
/// failed (offline) and the answer is unknown.
enum LookupResult { registered, notRegistered, failed }

/// Checks which numbers belong to app accounts. Injected so the matching is
/// testable without Firebase.
typedef DirectoryLookup = Future<Map<String, LookupResult>> Function(
    Set<String> e164s);

/// WhatsApp/Telegram-style contact discovery.
///
/// Every number of every contact (phone storage, synced accounts, SIM) is
/// normalized with the one phone helper — [normalizePhone], default country
/// = the user's own country, Sierra Leone if unknown — so `076…`, `76…`,
/// `+23276…` and `0023276…` all become `+23276…`. The distinct numbers are
/// then looked up directly as account keys (`users/{e164}`), in parallel
/// batches. The address book is never uploaded and nothing but the
/// account-key reads leaves the phone.
class ContactsRepository {
  static ContactSyncStats lastStats = const ContactSyncStats();

  static const int _batchSize = 40;
  static const Duration _lookupTimeout = Duration(seconds: 15);

  /// The full device contact list, one entry per person with all of their
  /// numbers. No account / SIM filter.
  static Future<List<DeviceContact>> readDeviceContacts() async {
    if (kIsWeb || Platform.isWindows) return [];

    // readonly:true asks for READ_CONTACTS only — the default also requests
    // WRITE_CONTACTS, which this app never declares, so the plugin's
    // combined check could never pass.
    final granted = await FlutterContacts.requestPermission(readonly: true);
    if (!granted) return [];

    var contacts = await FlutterContacts.getContacts(withProperties: true);
    if (contacts.isEmpty) {
      // provider occasionally not ready on the first call after a grant
      await Future<void>.delayed(const Duration(milliseconds: 400));
      contacts = await FlutterContacts.getContacts(withProperties: true);
    }

    final out = <DeviceContact>[];
    final seen = <String>{}; // raw digit strings already covered

    String digits(String s) => s.replaceAll(RegExp(r'\D'), '');

    for (final c in contacts) {
      final nums = <String>{};
      for (final p in c.phones) {
        final n = p.number.trim();
        if (n.isEmpty) continue;
        nums.add(n);
        seen.add(digits(n));
        // Android keeps a normalized copy too; harmless duplicate input.
        final norm = p.normalizedNumber.trim();
        if (norm.isNotEmpty) nums.add(norm);
      }
      if (nums.isEmpty) continue;
      final name = c.displayName.trim();
      out.add((name: name.isEmpty ? nums.first : name, numbers: nums.toList()));
    }

    // SIM-card contacts are not in ContactsContract; merge them as ordinary
    // contacts unless phone storage already had the same number.
    try {
      for (final s in await SimContacts.getAll()) {
        if (!seen.add(digits(s.number))) continue;
        out.add((name: s.name.isEmpty ? s.number : s.name, numbers: [s.number]));
      }
    } catch (e) {
      debugPrint('[Contacts] SIM merge failed: $e');
    }
    return out;
  }

  /// Account-key lookup against Firebase: `users/{e164}/uid` exists ⇔ the
  /// number is registered. Leaf reads keep every lookup tiny; batches run
  /// in parallel over the one database connection.
  static Future<Map<String, LookupResult>> firebaseLookup(
      Set<String> e164s) async {
    final out = <String, LookupResult>{};
    final list = e164s.toList();
    final users = FirebaseDatabase.instance.ref('users');
    for (var i = 0; i < list.length; i += _batchSize) {
      final batch = list.skip(i).take(_batchSize);
      await Future.wait(batch.map((e164) async {
        try {
          final snap =
              await users.child(e164).child('uid').get().timeout(_lookupTimeout);
          out[e164] = snap.value is String && (snap.value as String).isNotEmpty
              ? LookupResult.registered
              : LookupResult.notRegistered;
        } catch (_) {
          out[e164] = LookupResult.failed;
        }
      }));
    }
    return out;
  }

  /// Full device contact list, classified into app users vs. not.
  ///
  /// [previous] is the last saved book: numbers whose lookup fails this
  /// time (offline) keep the answer they had, so a bad connection never
  /// makes people disappear from the list.
  static Future<ContactBook> fetchContactBook({ContactBook? previous}) async {
    final profile = await AuthManager.getCachedProfile();
    final country = (profile?.country ?? '').trim().isEmpty
        ? kDefaultCountry
        : profile!.country.trim().toUpperCase();
    final contacts = await readDeviceContacts();
    final result = await matchContacts(
      contacts: contacts,
      defaultCountry: country,
      lookup: firebaseLookup,
      previous: previous,
      selfId: profile?.uid,
    );
    lastStats = result.stats;
    debugPrint('[Contacts] read=${result.stats.contactsRead} '
        'valid=${result.stats.validNumbers} onApp=${result.stats.onApp} '
        'failed=${result.stats.failedLookups}');
    return result.book;
  }
}

/// The matching itself, pure apart from [lookup]: normalize every number,
/// look the distinct E.164 numbers up once each, and build the book. A
/// person with several numbers is "on the app" if any of them is; two
/// phone-book entries for the same account become one row.
Future<({ContactBook book, ContactSyncStats stats})> matchContacts({
  required List<DeviceContact> contacts,
  required String defaultCountry,
  required DirectoryLookup lookup,
  ContactBook? previous,
  String? selfId,
}) async {
  var numbersRead = 0;
  final perContact = <List<String>>[];
  final distinct = <String>{};

  for (final c in contacts) {
    final keys = <String>[];
    for (final raw in c.numbers) {
      numbersRead++;
      final e164 = normalizePhone(raw, defaultCountry: defaultCountry);
      if (e164 == null) continue;
      final id = resolveUserId(e164);
      if (!keys.contains(id)) keys.add(id);
    }
    perContact.add(keys);
    distinct.addAll(keys);
  }

  final answers = distinct.isEmpty
      ? const <String, LookupResult>{}
      : await lookup(distinct);
  final previouslyOnApp = {
    for (final c in previous?.onApp ?? const <AppContact>[])
      if (c.uid != null) c.uid!,
  };

  bool registered(String id) => switch (answers[id]) {
        LookupResult.registered => true,
        LookupResult.failed => previouslyOnApp.contains(id),
        _ => false,
      };

  final onApp = <AppContact>[];
  final notOnApp = <AppContact>[];
  final seenUid = <String>{};
  for (var i = 0; i < contacts.length; i++) {
    final c = contacts[i];
    final keys = perContact[i];
    final hit = keys.where(registered).firstOrNull;
    if (hit != null) {
      if (seenUid.add(hit)) {
        onApp.add(AppContact(
            name: c.name, phone: hit, uid: hit, source: 'DEVICE'));
      }
    } else {
      notOnApp.add(AppContact(
        name: c.name,
        phone: keys.isNotEmpty ? keys.first : c.numbers.first,
        source: 'DEVICE',
      ));
    }
  }

  int byName(AppContact a, AppContact b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
  onApp.sort(byName);
  notOnApp.sort(byName);

  final stats = ContactSyncStats(
    contactsRead: contacts.length,
    numbersRead: numbersRead,
    validNumbers: distinct.length,
    onApp: onApp.where((c) => c.uid != selfId).length,
    failedLookups:
        answers.values.where((r) => r == LookupResult.failed).length,
    lastSync: DateTime.now(),
  );
  return (book: ContactBook(onApp: onApp, notOnApp: notOnApp), stats: stats);
}
