import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_contact.dart';
import 'contacts_repository.dart';
import 'display_names.dart';

/// App-wide cache of the classified contact book, saved on the phone so the
/// Contacts screen opens instantly with the last result — even offline or
/// right after a restart — while ContactSyncService refreshes it quietly.
class ContactsCache extends ChangeNotifier {
  ContactsCache._internal();
  static final ContactsCache instance = ContactsCache._internal();

  static const String _prefsKey = 'contact_book_v2';

  ContactBook _book = const ContactBook();
  ContactBook get book => _book;

  ContactSyncStats _stats = const ContactSyncStats();
  ContactSyncStats get stats => _stats;

  /// App-user contacts only — for callers like the "start a discussion"
  /// picker that only care about users you can message in-app.
  List<AppContact> get contacts => _book.onApp;

  bool hasLoadedOnce = false;
  bool _restored = false;

  /// When the book was last rebuilt from a full scan.
  DateTime? get lastSyncAt => _stats.lastSync;

  bool syncedWithin(Duration window) {
    final t = lastSyncAt;
    return t != null && DateTime.now().difference(t) < window;
  }

  /// Restores the last saved book. Cheap after the first call.
  Future<void> load() async {
    if (_restored) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || hasLoadedOnce) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _book = ContactBook(
        onApp: _contacts(j['onApp']),
        notOnApp: _contacts(j['notOnApp']),
      );
      if (j['stats'] is Map) _stats = ContactSyncStats.fromJson(j['stats']);
      hasLoadedOnce = true;
      notifyListeners();
    } catch (e) {
      debugPrint('ContactsCache: restore failed: $e');
    }
  }

  static List<AppContact> _contacts(Object? list) => [
        if (list is List)
          for (final m in list.whereType<Map>())
            AppContact(
              name: (m['n'] ?? '') as String,
              phone: (m['p'] ?? '') as String,
              uid: m['u'] as String?,
              source: 'DEVICE',
            ),
      ];

  static List<Map<String, Object?>> _encode(List<AppContact> list) => [
        for (final c in list)
          {'n': c.name, 'p': c.phone, if (c.uid != null) 'u': c.uid},
      ];

  void setBook(ContactBook value, ContactSyncStats stats) {
    _book = value;
    _stats = stats;
    hasLoadedOnce = true;
    notifyListeners();
    // Saved-contact names drive every name shown in the app.
    DisplayNames.instance.updateFromContacts(value.onApp);
    _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey,
          jsonEncode({
            'onApp': _encode(_book.onApp),
            'notOnApp': _encode(_book.notOnApp),
            'stats': _stats.toJson(),
          }));
    } catch (e) {
      debugPrint('ContactsCache: save failed: $e');
    }
  }

  void clear() {
    _book = const ContactBook();
    _stats = const ContactSyncStats();
    hasLoadedOnce = false;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.remove(_prefsKey));
  }
}
