import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:firebase_database/firebase_database.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_contact.dart';
import 'chat_summary.dart';
import 'contacts_cache.dart';
import 'contacts_repository.dart';
import 'local_contact_store.dart';

/// Background contacts sync — the coroutine-based equivalent of a
/// WorkManager job. Runs at app launch (see AuthGate._setReady) and on
/// manual pull-to-refresh (ContactScreen), never inline with a render.
///
/// Combines two sources into LocalContactStore, WhatsApp/Telegram-style:
///  1. Device contacts whose number matches a registered user
///     (ContactsRepository — already reads the OS's unified Contacts
///     Provider, which folds in phone storage, SIM, and any synced
///     Google/Gmail accounts; there is no separate per-source API to
///     call on Android, this one query already covers all of them).
///  2. Registered users the current user has an open chat with
///     (`userChats/{uid}`) who are NOT in device contacts — shown by
///     phone number, same as an unsaved chat handle.
///
/// Contacts permission is optional here: if it isn't granted, the device
/// side is skipped entirely and only the chat-only list is synced, so the
/// Contacts screen still has something useful instead of going empty.
class ContactsSyncService {
  ContactsSyncService._();

  static Future<void> sync(String currentUid) async {
    try {
      final hasPermission = await _hasContactsPermission();

      if (hasPermission) {
        final deviceMatched = await ContactsRepository.fetchMatchedContacts();
        // Chat-only rows are written first so device-matched rows (below)
        // win on any phone-number collision — see LocalContactStore's
        // class doc for why that ordering matters.
        await _syncChatOnly(currentUid, excludePhones: deviceMatched.map((c) => c.phone).toSet());
        await LocalContactStore.instance.replaceSource('DEVICE', deviceMatched);
      } else {
        await _syncChatOnly(currentUid, excludePhones: const {});
        // No device permission — don't touch/clear any previously-synced
        // DEVICE rows (they were legitimately fetched before permission
        // was revoked); just leave them as the last-known-good snapshot.
      }

      final all = await LocalContactStore.instance.getAll();
      ContactsCache.instance.setContacts(all);
      ContactsCache.instance.hasLoadedOnce = true;
    } catch (e) {
      debugPrint('ContactsSyncService: sync failed: $e');
    }
  }

  static Future<bool> _hasContactsPermission() async {
    if (kIsWeb) return false;
    final status = await Permission.contacts.status;
    return status.isGranted;
  }

  static Future<void> _syncChatOnly(
    String currentUid, {
    required Set<String> excludePhones,
  }) async {
    try {
      final snapshot = await FirebaseDatabase.instance.ref('userChats/$currentUid').get();
      if (!snapshot.exists || snapshot.value is! Map) {
        await LocalContactStore.instance.replaceSource('CHAT_ONLY', const []);
        return;
      }

      final chatOnly = <AppContact>[];
      (snapshot.value as Map).forEach((key, value) {
        if (value is! Map) return;
        final summary = ChatSummary.fromMap(key.toString(), value);
        if (summary.otherUid.isEmpty) return;
        // otherUid IS the other user's E.164 phone number (see UserProfile
        // doc) — that's what lets this dedup directly against device
        // contact phone numbers with no extra lookup.
        if (excludePhones.contains(summary.otherUid)) return;

        chatOnly.add(AppContact(
          name: summary.otherName.isEmpty ? summary.otherUid : summary.otherName,
          phone: summary.otherUid,
          uid: summary.otherUid,
          photoUrl: summary.otherPhotoUrl.isEmpty ? null : summary.otherPhotoUrl,
          source: 'CHAT_ONLY',
        ));
      });

      await LocalContactStore.instance.replaceSource('CHAT_ONLY', chatOnly);
    } catch (e) {
      debugPrint('ContactsSyncService: chat-only sync failed: $e');
    }
  }
}
