import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Admin screen's PIN.
///
/// Only a SHA-256 hash is ever stored — in the database at
/// `config/adminPinHash` (so the PIN can be changed without an app update)
/// and, as a fallback for offline use or a missing database value, here in
/// the app. The plain PIN is not in the code.
///
/// The last hash read from the database is remembered on the phone, so a
/// PIN changed in the database keeps working offline and the old one stops
/// working once the phone has seen the new hash.
///
/// After [maxAttempts] wrong PINs, entry is locked for [lockout]. A correct
/// PIN unlocks Admin for the rest of the app session.
class AdminPin {
  AdminPin({
    DateTime Function()? clock,
    Future<String?> Function()? remoteHash,
  })  : _now = clock ?? DateTime.now,
        _remoteHash = remoteHash ?? _readRemoteHash;

  static final AdminPin instance = AdminPin();

  /// SHA-256 of the default PIN — used when the database value is missing
  /// and none has been seen before.
  static const String fallbackHash =
      'edee29f882543b956620b26d0ee0e7e950399b1c4222f5de05e06425b4c995e9';

  static const String databasePath = 'config/adminPinHash';
  static const int maxAttempts = 5;
  static const Duration lockout = Duration(seconds: 30);
  static const String _prefsKey = 'admin_pin_hash_v1';

  final DateTime Function() _now;
  final Future<String?> Function() _remoteHash;

  bool _unlocked = false;
  int _failures = 0;
  DateTime? _lockedUntil;

  /// True once the right PIN was entered in this app session.
  bool get unlockedThisSession => _unlocked;

  /// While locked out after too many wrong PINs: how long is left.
  Duration? get lockRemaining {
    final until = _lockedUntil;
    if (until == null) return null;
    final left = until.difference(_now());
    if (left <= Duration.zero) {
      _lockedUntil = null;
      _failures = 0;
      return null;
    }
    return left;
  }

  static String hashOf(String pin) =>
      sha256.convert(utf8.encode(pin.trim())).toString();

  static bool _isHash(Object? v) =>
      v is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(v);

  static Future<String?> _readRemoteHash() async {
    final snap = await FirebaseDatabase.instance
        .ref(databasePath)
        .get()
        .timeout(const Duration(seconds: 6));
    final v = snap.value;
    return _isHash(v) ? v as String : null;
  }

  /// The hash to compare against: database → last one seen → built-in.
  Future<String> _expectedHash() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    try {
      final remote = await _remoteHash();
      if (remote != null) {
        await prefs?.setString(_prefsKey, remote);
        return remote;
      }
    } catch (e) {
      debugPrint('AdminPin: database hash unavailable ($e), using saved/built-in');
    }
    final saved = prefs?.getString(_prefsKey);
    return _isHash(saved) ? saved! : fallbackHash;
  }

  /// Checks [pin]. Returns null on success, otherwise the message to show.
  Future<String?> verify(String pin) async {
    final left = lockRemaining;
    if (left != null) {
      return 'Too many wrong tries. Try again in ${left.inSeconds + 1} s.';
    }
    if (!RegExp(r'^\d{4}$').hasMatch(pin.trim())) {
      return 'Enter the 4-digit PIN.';
    }
    if (hashOf(pin) == await _expectedHash()) {
      _unlocked = true;
      _failures = 0;
      return null;
    }
    _failures++;
    if (_failures >= maxAttempts) {
      _lockedUntil = _now().add(lockout);
      return 'Wrong PIN. Too many tries — wait ${lockout.inSeconds} seconds.';
    }
    final remaining = maxAttempts - _failures;
    return 'Wrong PIN ($remaining ${remaining == 1 ? 'try' : 'tries'} left).';
  }
}
