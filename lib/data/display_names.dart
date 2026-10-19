import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/phone_utils.dart';
import 'app_contact.dart';
import 'phone_aliases.dart';

export '../util/phone_utils.dart' show formatPhoneForDisplay;

/// WhatsApp-style naming, used everywhere a person is shown (chat list,
/// chat header, audio feed, calls, notifications):
///
///  * number saved in MY phone's contacts → the name I saved it under;
///  * not saved → the phone number only, never the name they picked for
///    their own profile.
///
/// Fed by the automatic contact sync (ContactSyncService) and persisted, so
/// names are right from the first frame and offline. The same map is read
/// natively by ContactDisplayNames.kt for notifications shown while the app
/// is closed — keep [prefsKey] and the JSON shape in sync with it.
class DisplayNames extends ChangeNotifier {
  DisplayNames._();
  static final DisplayNames instance = DisplayNames._();

  /// shared_preferences stores this as "flutter.display_names_v1" in the
  /// FlutterSharedPreferences file on Android.
  static const String prefsKey = 'display_names_v1';

  /// Saved-contact name keyed by app user id (= E.164 phone).
  Map<String, String> _saved = const {};
  bool _loaded = false;

  Map<String, String> get savedNames => _saved;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _saved = {
          for (final e in decoded.entries)
            if (e.value is String) e.key.toString(): e.value as String,
        };
        notifyListeners();
      }
    } catch (e) {
      debugPrint('DisplayNames: load failed: $e');
    }
  }

  /// Replace the saved-name map from a fresh contact sync.
  Future<void> updateFromContacts(List<AppContact> onApp) async {
    final next = savedNamesFrom(onApp);
    if (mapEquals(next, _saved)) return;
    _saved = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(next));
    } catch (e) {
      debugPrint('DisplayNames: save failed: $e');
    }
  }

  bool isSaved(String uid) => _saved.containsKey(uid);

  /// The name to show for [uid] (an E.164 phone number).
  String nameFor(String uid) => resolveDisplayName(uid, _saved);

  @visibleForTesting
  void debugSetSaved(Map<String, String> saved) {
    _saved = saved;
    notifyListeners();
  }
}

/// Saved-contact names keyed by both the user's id and phone (they're the
/// same E.164 string for every current account, but older records may
/// differ). Both are canonicalised so lookups match.
Map<String, String> savedNamesFrom(List<AppContact> onApp) {
  final out = <String, String>{};
  for (final c in onApp) {
    final name = c.name.trim();
    if (name.isEmpty) continue;
    final uid = c.uid;
    if (uid != null && uid.isNotEmpty) {
      out[uid] = name;
      out.putIfAbsent(canonicalUserId(uid), () => name);
    }
    if (c.phone.isNotEmpty) {
      out.putIfAbsent(c.phone, () => name);
      out.putIfAbsent(canonicalUserId(c.phone), () => name);
    }
  }
  return out;
}

/// Saved name if [uid] is in [saved], otherwise the formatted number.
/// [uid] may come from old data (`+031932652`, a moved account key), so
/// the canonical id is looked up too.
String resolveDisplayName(String uid, Map<String, String> saved) {
  final name = saved[uid] ?? saved[resolveUserId(uid)];
  if (name != null && name.trim().isNotEmpty) return name;
  if (uid.isEmpty) return 'Unknown';
  return formatPhoneForDisplay(resolveUserId(uid));
}
