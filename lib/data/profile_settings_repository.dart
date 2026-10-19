import 'dart:async';
import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where profile edits are written. Injected so saving is testable without
/// Firebase.
abstract class ProfileBackend {
  /// True when the database connection is up right now.
  Future<bool> isOnline();

  /// One multi-path update at the database root: only the listed leaf
  /// paths change, every other field stays exactly as it is.
  Future<void> updatePaths(Map<String, Object?> paths);

  /// My chats: chat id → the other person's id (from `userChats/{me}`).
  Future<Map<String, String>> chatPartners(String myUid);
}

class FirebaseProfileBackend implements ProfileBackend {
  FirebaseDatabase get _db => FirebaseDatabase.instance;

  @override
  Future<bool> isOnline() async {
    try {
      final e = await _db
          .ref('.info/connected')
          .onValue
          .first
          .timeout(const Duration(seconds: 3));
      return e.snapshot.value == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> updatePaths(Map<String, Object?> paths) =>
      _db.ref().update(paths).timeout(const Duration(seconds: 20));

  @override
  Future<Map<String, String>> chatPartners(String myUid) async {
    final snap = await _db
        .ref('userChats/$myUid')
        .get()
        .timeout(const Duration(seconds: 10));
    final out = <String, String>{};
    final v = snap.value;
    if (v is Map) {
      v.forEach((cid, s) {
        final other = s is Map ? s['otherUid'] : null;
        if (other is String && other.isNotEmpty) out[cid.toString()] = other;
      });
    }
    return out;
  }
}

/// A profile change waiting to reach the database.
@immutable
class PendingProfileEdit {
  final String uid;
  final String? name;
  final String? photoUrl; // Base64 JPEG; '' removes the photo
  final int updatedAt;

  const PendingProfileEdit({
    required this.uid,
    this.name,
    this.photoUrl,
    required this.updatedAt,
  });

  bool get isEmpty => name == null && photoUrl == null;

  Map<String, Object?> toJson() => {
        'uid': uid,
        if (name != null) 'name': name,
        if (photoUrl != null) 'photoUrl': photoUrl,
        'updatedAt': updatedAt,
      };

  factory PendingProfileEdit.fromJson(Map<String, dynamic> j) =>
      PendingProfileEdit(
        uid: j['uid'] as String,
        name: j['name'] as String?,
        photoUrl: j['photoUrl'] as String?,
        updatedAt: (j['updatedAt'] as num).toInt(),
      );

  /// A newer edit on top of this one (name and photo can change separately).
  PendingProfileEdit merge(PendingProfileEdit newer) => PendingProfileEdit(
        uid: newer.uid,
        name: newer.name ?? name,
        photoUrl: newer.photoUrl ?? photoUrl,
        updatedAt: newer.updatedAt,
      );
}

enum ProfileSaveResult { saved, queuedOffline }

/// Saves the Settings screen (account name, profile photo).
///
///  * Writes only `users/{me}/name`, `photoUrl` and `updatedAt` — never the
///    whole record, so the push id, auth link, device id, admin flags and
///    anything else stay untouched.
///  * Also refreshes my name/photo in my chat partners' chat lists
///    (`userChats/{other}/{chatId}`), which older app versions display.
///  * Offline, the edit is kept on the phone and sent automatically when
///    the connection returns (and at the next app start).
class ProfileSettingsRepository {
  ProfileSettingsRepository({ProfileBackend? backend, DateTime Function()? clock})
      : _backend = backend ?? FirebaseProfileBackend(),
        _now = clock ?? DateTime.now;

  static final ProfileSettingsRepository instance = ProfileSettingsRepository();

  static const String _prefsKey = 'pending_profile_edit_v1';
  static const int nameMin = 2;
  static const int nameMax = 40;

  final ProfileBackend _backend;
  final DateTime Function() _now;
  StreamSubscription<DatabaseEvent>? _connectedSub;
  bool _flushing = false;

  /// "  Pastor   John " → "Pastor John".
  static String cleanName(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Error text for the Account name field, or null when it's fine.
  static String? validateName(String raw) {
    final name = cleanName(raw);
    if (name.isEmpty) return 'Please enter your account name';
    if (name.runes.length < nameMin) {
      return 'At least $nameMin characters';
    }
    if (name.runes.length > nameMax) {
      return 'At most $nameMax characters';
    }
    return null;
  }

  /// Saves the changed fields ([name] and/or [photoUrl]; '' removes the
  /// photo). Throws if the database rejects the write while online — the
  /// edit then stays queued.
  Future<ProfileSaveResult> save({
    required String uid,
    String? name,
    String? photoUrl,
  }) async {
    final edit = PendingProfileEdit(
      uid: uid,
      name: name == null ? null : cleanName(name),
      photoUrl: photoUrl,
      updatedAt: _now().millisecondsSinceEpoch,
    );
    if (edit.isEmpty) return ProfileSaveResult.saved;
    await _queue(edit);
    if (!await _backend.isOnline()) return ProfileSaveResult.queuedOffline;
    await flushPending(throwOnError: true);
    return ProfileSaveResult.saved;
  }

  /// Sends a queued edit, if any. Returns true when nothing is left queued.
  Future<bool> flushPending({bool throwOnError = false}) async {
    if (_flushing) return false;
    _flushing = true;
    try {
      final edit = await pending();
      if (edit == null) return true;
      final u = 'users/${edit.uid}';
      await _backend.updatePaths({
        if (edit.name != null) '$u/name': edit.name,
        if (edit.photoUrl != null) '$u/photoUrl': edit.photoUrl,
        '$u/updatedAt': edit.updatedAt,
      });
      await _clearIfUnchanged(edit);
      unawaited(_updatePartnerSummaries(edit));
      return true;
    } catch (e) {
      debugPrint('ProfileSettings: save failed, kept for later: $e');
      if (throwOnError) rethrow;
      return false;
    } finally {
      _flushing = false;
    }
  }

  /// Retry the queued edit whenever the database connection comes back.
  void startAutoSync() {
    _connectedSub ??= FirebaseDatabase.instance
        .ref('.info/connected')
        .onValue
        .listen((e) {
      if (e.snapshot.value == true) unawaited(flushPending());
    });
  }

  Future<PendingProfileEdit?> pending() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return null;
    try {
      return PendingProfileEdit.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await prefs.remove(_prefsKey);
      return null;
    }
  }

  Future<void> _queue(PendingProfileEdit edit) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await pending();
    final merged =
        existing != null && existing.uid == edit.uid ? existing.merge(edit) : edit;
    await prefs.setString(_prefsKey, jsonEncode(merged.toJson()));
  }

  // A newer edit queued while this one was in flight must survive.
  Future<void> _clearIfUnchanged(PendingProfileEdit sent) async {
    final now = await pending();
    if (now != null && now.updatedAt != sent.updatedAt) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  Future<void> _updatePartnerSummaries(PendingProfileEdit edit) async {
    try {
      final partners = await _backend.chatPartners(edit.uid);
      if (partners.isEmpty) return;
      await _backend.updatePaths({
        for (final e in partners.entries) ...{
          if (edit.name != null)
            'userChats/${e.value}/${e.key}/otherName': edit.name,
          if (edit.photoUrl != null)
            'userChats/${e.value}/${e.key}/otherPhotoUrl': edit.photoUrl,
        },
      });
    } catch (e) {
      // Cosmetic only (older app versions' chat lists); never fail a save.
      debugPrint('ProfileSettings: chat-list refresh skipped: $e');
    }
  }
}
