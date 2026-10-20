import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/phone_utils.dart';

/// `phoneAliases/{oldWrongKey}` → correct E.164 account id.
///
/// Written by tools/fix_phone_numbers.js (and by the on-device self-repair)
/// whenever an account saved under a malformed number is moved to its
/// correct key. Feed posts, chat ids and call records written by older app
/// versions can still carry the old key; every id that comes from stored
/// data is passed through [resolve] before it is used, so those still lead
/// to the right person.
class PhoneAliases {
  PhoneAliases._();
  static final PhoneAliases instance = PhoneAliases._();

  static const String _prefsKey = 'phone_aliases_v1';

  Map<String, String> _aliases = const {};
  bool _refreshing = false;

  /// The table saved on the phone — instant, works offline.
  Future<void> loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) _aliases = _parse(jsonDecode(raw));
    } catch (e) {
      debugPrint('PhoneAliases: cached table unreadable: $e');
    }
  }

  /// Background refresh from Firebase. Never needed to show any screen; on
  /// a slow or missing connection it simply keeps the cached table.
  /// Returns true when the table changed.
  Future<bool> refresh() async {
    if (_refreshing) return false;
    _refreshing = true;
    try {
      final snap = await FirebaseDatabase.instance
          .ref('phoneAliases')
          .get()
          .timeout(const Duration(seconds: 15));
      final fresh = _parse(snap.value);
      if (mapEquals(fresh, _aliases)) return false;
      _aliases = fresh;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(fresh));
      return true;
    } catch (_) {
      return false; // offline / slow: the cached copy stays in use
    } finally {
      _refreshing = false;
    }
  }

  static Map<String, String> _parse(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final e in value.entries)
        if (e.value is String && (e.value as String).isNotEmpty)
          e.key.toString(): e.value as String,
    };
  }

  /// The current account id for [id]: the alias target if the server moved
  /// this key, otherwise the id repaired to strict E.164 (or unchanged for
  /// a non-phone legacy id).
  /// The alias target for an id that is already strict E.164 (no parsing).
  String aliasFor(String e164) => _aliases[e164] ?? e164;

  String resolve(String id) {
    final t = id.trim();
    if (t.isEmpty) return t;
    return _aliases[t] ?? canonicalUserId(t);
  }

  @visibleForTesting
  void debugSet(Map<String, String> aliases) => _aliases = aliases;
}

/// Shorthand for [PhoneAliases.resolve].
String resolveUserId(String id) => PhoneAliases.instance.resolve(id);
